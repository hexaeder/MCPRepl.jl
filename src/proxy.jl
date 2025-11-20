"""
Persistent MCP Proxy Server

Provides a stable MCP interface that routes requests to backend REPL processes.
The proxy server runs independently and stays up even when backend REPLs restart.
"""
module Proxy

using HTTP
using JSON
using Sockets
using Dates

# REPL Connection tracking
mutable struct REPLConnection
    id::String                          # Unique identifier (project name, agent name)
    port::Int                           # REPL's MCP server port
    pid::Union{Int,Nothing}            # REPL process ID
    status::Symbol                      # :ready, :restarting, :stopped
    last_heartbeat::DateTime            # Last time we heard from this REPL
    metadata::Dict{String,Any}         # Additional info (project path, etc.)
    last_error::Union{String,Nothing}  # Last error message if any
    missed_heartbeats::Int             # Counter for consecutive missed heartbeats
end

# Global state
const SERVER = Ref{Union{HTTP.Server,Nothing}}(nothing)
const SERVER_PORT = Ref{Int}(3000)
const SERVER_PID_FILE = Ref{String}("")
const REPL_REGISTRY = Dict{String,REPLConnection}()
const REPL_REGISTRY_LOCK = ReentrantLock()

"""
    is_server_running(port::Int=3000) -> Bool

Check if a proxy server is already running on the specified port.
"""
function is_server_running(port::Int=3000)
    try
        # Try to connect to the port
        sock = connect(ip"127.0.0.1", port)
        close(sock)
        return true
    catch
        return false
    end
end

"""
    get_server_pid(port::Int=3000) -> Union{Int, Nothing}

Get the PID of the running proxy server from the PID file.
Returns nothing if no PID file exists or process is not running.
"""
function get_server_pid(port::Int=3000)
    pid_file = get_pid_file_path(port)

    if !isfile(pid_file)
        return nothing
    end

    try
        pid_str = strip(read(pid_file, String))
        pid = parse(Int, pid_str)

        # Verify process is actually running using parent module's Utils
        if isdefined(Main, :MCPRepl) && isdefined(Main.MCPRepl, :Utils)
            if Main.MCPRepl.Utils.process_running(pid)
                return pid
            else
                # Stale PID file, remove it
                rm(pid_file, force=true)
                return nothing
            end
        else
            # Can't verify, assume running
            return pid
        end
    catch
        return nothing
    end
end

"""
    get_pid_file_path(port::Int=3000) -> String

Get the path to the PID file for a proxy server on the given port.
"""
function get_pid_file_path(port::Int=3000)
    cache_dir = get(ENV, "XDG_CACHE_HOME") do
        if Sys.iswindows()
            joinpath(ENV["LOCALAPPDATA"], "MCPRepl")
        else
            joinpath(homedir(), ".cache", "mcprepl")
        end
    end

    mkpath(cache_dir)
    return joinpath(cache_dir, "proxy-$port.pid")
end

"""
    write_pid_file(port::Int=3000)

Write the current process PID to the PID file.
"""
function write_pid_file(port::Int=3000)
    pid_file = get_pid_file_path(port)
    write(pid_file, string(getpid()))
    SERVER_PID_FILE[] = pid_file
end

"""
    remove_pid_file(port::Int=3000)

Remove the PID file for the proxy server.
"""
function remove_pid_file(port::Int=3000)
    pid_file = get_pid_file_path(port)
    rm(pid_file, force=true)
end

# ============================================================================
# REPL Registry Management
# ============================================================================

"""
    register_repl(id::String, port::Int; pid::Union{Int,Nothing}=nothing, metadata::Dict=Dict())

Register a REPL with the proxy server so it can route requests to it.

# Arguments
- `id::String`: Unique identifier for this REPL (e.g., "project-a", "agent-1")
- `port::Int`: Port where the REPL's MCP server is listening
- `pid::Union{Int,Nothing}=nothing`: Process ID of the REPL (optional)
- `metadata::Dict=Dict()`: Additional metadata (project path, etc.)
"""
function register_repl(id::String, port::Int; pid::Union{Int,Nothing}=nothing, metadata::Dict=Dict())
    lock(REPL_REGISTRY_LOCK) do
        REPL_REGISTRY[id] = REPLConnection(
            id,
            port,
            pid,
            :ready,
            now(),
            metadata,
            nothing,
            0
        )
        @info "REPL registered with proxy" id = id port = port pid = pid
    end
end

"""
    unregister_repl(id::String)

Remove a REPL from the proxy registry.
"""
function unregister_repl(id::String)
    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, id)
            delete!(REPL_REGISTRY, id)
            @info "REPL unregistered from proxy" id = id
        end
    end
end

"""
    get_repl(id::String) -> Union{REPLConnection, Nothing}

Get a REPL connection by ID.
"""
function get_repl(id::String)
    lock(REPL_REGISTRY_LOCK) do
        get(REPL_REGISTRY, id, nothing)
    end
end

"""
    list_repls() -> Vector{REPLConnection}

List all registered REPLs.
"""
function list_repls()
    lock(REPL_REGISTRY_LOCK) do
        collect(values(REPL_REGISTRY))
    end
end

"""  
    update_repl_status(id::String, status::Symbol; error::Union{String,Nothing}=nothing)

Update the status of a registered REPL, optionally storing error information.
"""
function update_repl_status(id::String, status::Symbol; error::Union{String,Nothing}=nothing)
    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, id)
            REPL_REGISTRY[id].status = status
            REPL_REGISTRY[id].last_heartbeat = now()
            if error !== nothing
                REPL_REGISTRY[id].last_error = error
                # Increment missed heartbeats counter on errors
                REPL_REGISTRY[id].missed_heartbeats += 1
            elseif status == :ready
                # Clear error and reset counter when back to ready
                REPL_REGISTRY[id].last_error = nothing
                REPL_REGISTRY[id].missed_heartbeats = 0
            end
        end
    end
end

"""
    route_to_repl(request::Dict, original_req::HTTP.Request) -> HTTP.Response

Route a request to the appropriate backend REPL.

Uses the X-MCPRepl-Target header to determine which REPL to route to.
If no header is present, routes to the first available REPL.
"""
function route_to_repl(request::Dict, original_req::HTTP.Request)
    # Determine target REPL
    header_value = HTTP.header(original_req, "X-MCPRepl-Target")
    # HTTP.header returns a SubString{String} or String
    target_id = isempty(header_value) ? nothing : String(header_value)

    if target_id === nothing
        # No target specified, try to use first available REPL
        repls = list_repls()
        if isempty(repls)
            return HTTP.Response(503, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "error" => Dict(
                    "code" => -32001,
                    "message" => "No REPLs registered with proxy. Please start a REPL with MCPRepl.start!()"
                )
            )))
        end
        target_id = first(repls).id
    end

    # Get the REPL connection
    repl = get_repl(target_id)

    if repl === nothing
        return HTTP.Response(404, JSON.json(Dict(
            "jsonrpc" => "2.0",
            "id" => get(request, "id", nothing),
            "error" => Dict(
                "code" => -32002,
                "message" => "REPL not found: $target_id"
            )
        )))
    end

    if repl.status != :ready
        # If stopped, try one recovery attempt by marking as ready
        # (maybe the REPL recovered but we didn't know)
        if repl.status == :stopped
            @info "Attempting recovery for stopped REPL" id = target_id
            update_repl_status(target_id, :ready)
            repl = get_repl(target_id)
            if repl === nothing || repl.status != :ready
                return HTTP.Response(503, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32003,
                        "message" => "REPL not ready: $(repl.status)"
                    )
                )))
            end
        else
            return HTTP.Response(503, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "error" => Dict(
                    "code" => -32003,
                    "message" => "REPL not ready: $(repl.status)"
                )
            )))
        end
    end

    # Forward request to backend REPL
    try
        backend_url = "http://127.0.0.1:$(repl.port)/"
        headers = ["Content-Type" => "application/json"]
        body_str = JSON.json(request)
        @debug "Forwarding to backend" url = backend_url headers = headers body_length = length(body_str)
        response = HTTP.post(
            backend_url,
            headers,
            body_str;
            readtimeout=30,
            connect_timeout=5
        )

        # Update last heartbeat
        update_repl_status(target_id, :ready)

        return HTTP.Response(response.status, response.body)
    catch e
        # Capture full error with stack trace
        io = IOBuffer()
        showerror(io, e, catch_backtrace())
        error_msg = String(take!(io))
        @error "Error forwarding request to REPL" target = target_id exception = e

        # Store the error and increment missed heartbeat counter
        error_summary = length(error_msg) > 500 ? error_msg[1:500] * "..." : error_msg

        # Only mark as stopped after 3 consecutive failures
        lock(REPL_REGISTRY_LOCK) do
            if haskey(REPL_REGISTRY, target_id)
                REPL_REGISTRY[target_id].last_error = error_summary
                REPL_REGISTRY[target_id].missed_heartbeats += 1

                if REPL_REGISTRY[target_id].missed_heartbeats >= 3
                    REPL_REGISTRY[target_id].status = :stopped
                    @warn "REPL marked as stopped after 3 consecutive failures" id = target_id
                else
                    @info "REPL error ($(REPL_REGISTRY[target_id].missed_heartbeats)/3 failures)" id = target_id
                end
            end
        end

        return HTTP.Response(502, JSON.json(Dict(
            "jsonrpc" => "2.0",
            "id" => get(request, "id", nothing),
            "error" => Dict(
                "code" => -32004,
                "message" => "Failed to connect to REPL: $(sprint(showerror, e))"
            )
        )))
    end
end

"""
    handle_request(req::HTTP.Request) -> HTTP.Response

Handle incoming MCP requests. Routes to appropriate backend REPL or handles proxy commands.
"""
function handle_request(req::HTTP.Request)
    try
        # Parse request body
        body = String(req.body)

        if isempty(body)
            # Health check endpoint
            return HTTP.Response(200, JSON.json(Dict(
                "status" => "ok",
                "type" => "mcprepl-proxy",
                "version" => "0.1.0",
                "pid" => getpid(),
                "uptime" => time()
            )))
        end

        # Parse JSON-RPC request
        request = JSON.parse(body)

        # Handle proxy-specific methods
        method = get(request, "method", "")

        if method == "proxy/status"
            repls = list_repls()
            return HTTP.Response(200, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict(
                    "status" => "running",
                    "pid" => getpid(),
                    "port" => SERVER_PORT[],
                    "connected_repls" => length(repls),
                    "repls" => [Dict(
                        "id" => r.id,
                        "port" => r.port,
                        "status" => string(r.status),
                        "pid" => r.pid,
                        "last_error" => r.last_error
                    ) for r in repls],
                    "uptime" => time()
                )
            )))
        elseif method == "proxy/register"
            # Register a new REPL
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)
            port = get(params, "port", nothing)
            pid = get(params, "pid", nothing)
            metadata_raw = get(params, "metadata", Dict())

            # Convert JSON.Object to Dict if needed
            metadata = metadata_raw isa Dict ? metadata_raw : Dict(String(k) => v for (k, v) in pairs(metadata_raw))

            if id === nothing || port === nothing
                return HTTP.Response(400, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32602,
                        "message" => "Invalid params: 'id' and 'port' are required"
                    )
                )))
            end

            register_repl(id, port; pid=pid, metadata=metadata)

            return HTTP.Response(200, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict("status" => "registered", "id" => id)
            )))
        elseif method == "proxy/unregister"
            # Unregister a REPL
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                return HTTP.Response(400, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32602,
                        "message" => "Invalid params: 'id' is required"
                    )
                )))
            end

            unregister_repl(id)

            return HTTP.Response(200, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict("status" => "unregistered", "id" => id)
            )))
        elseif method == "proxy/heartbeat"
            # REPL sends heartbeat to indicate it's alive
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                return HTTP.Response(400, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32602,
                        "message" => "Invalid params: 'id' is required"
                    )
                )))
            end

            # Update heartbeat and recover from stopped state
            lock(REPL_REGISTRY_LOCK) do
                if haskey(REPL_REGISTRY, id)
                    REPL_REGISTRY[id].last_heartbeat = now()
                    REPL_REGISTRY[id].missed_heartbeats = 0  # Reset counter on successful heartbeat
                    # Automatically recover from stopped state on heartbeat
                    if REPL_REGISTRY[id].status == :stopped
                        REPL_REGISTRY[id].status = :ready
                        REPL_REGISTRY[id].last_error = nothing
                        @info "REPL recovered from stopped state via heartbeat" id = id
                    end
                end
            end

            return HTTP.Response(200, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict("status" => "ok")
            )))
        else
            # Route to backend REPL
            # Convert JSON.Object to Dict if needed
            request_dict = request isa Dict ? request : Dict(String(k) => v for (k, v) in pairs(request))
            return route_to_repl(request_dict, req)
        end

    catch e
        @error "Error handling request" exception = (e, catch_backtrace())
        return HTTP.Response(500, JSON.json(Dict(
            "error" => "Internal server error: $(sprint(showerror, e))"
        )))
    end
end

"""
    start_server(port::Int=3000; background::Bool=false) -> Union{HTTP.Server, Nothing}

Start the persistent MCP proxy server.

# Arguments
- `port::Int=3000`: Port to listen on
- `background::Bool=false`: If true, run in background process

# Returns
- HTTP.Server if running in foreground
- nothing if started in background
"""
function start_server(port::Int=3000; background::Bool=false)
    if is_server_running(port)
        existing_pid = get_server_pid(port)
        if existing_pid !== nothing
            @info "Proxy server already running on port $port (PID: $existing_pid)"
            return nothing
        end
    end

    if background
        # Start server in background process
        return start_background_server(port)
    else
        # Start server in current process
        return start_foreground_server(port)
    end
end

"""
    start_foreground_server(port::Int=3000) -> HTTP.Server

Start the proxy server in the current process.
"""
function start_foreground_server(port::Int=3000)
    if SERVER[] !== nothing
        @warn "Server already running in this process"
        return SERVER[]
    end

    SERVER_PORT[] = port
    write_pid_file(port)

    @info "Starting MCP Proxy Server" port = port pid = getpid()

    # Setup cleanup on exit
    atexit(() -> remove_pid_file(port))

    # Start HTTP server
    server = HTTP.serve!(handle_request, ip"127.0.0.1", port; verbose=false)
    SERVER[] = server

    @info "MCP Proxy Server started successfully" port = port pid = getpid()

    return server
end

"""
    start_background_server(port::Int=3000) -> Nothing

Start the proxy server in a detached background process.
"""
function start_background_server(port::Int=3000)
    # Create a Julia script that starts the server
    script = """
    using Pkg
    Pkg.activate("$(Base.active_project())")

    using MCPRepl.Proxy

    println("Starting MCP Proxy Server in background...")
    Proxy.start_foreground_server($port)

    # Keep server running
    println("Press Ctrl+C to stop the server")
    try
        wait(Proxy.SERVER[])
    catch e
        @warn "Server stopped" exception=e
    end
    """

    script_file = tempname() * ".jl"
    write(script_file, script)

    # Start detached Julia process
    @info "Launching background proxy server" port = port

    if Sys.iswindows()
        # Windows: use START command
        run(`cmd /c start julia $script_file`, wait=false)
    else
        # Unix: use nohup and redirect output
        log_file = joinpath(dirname(get_pid_file_path(port)), "proxy-$port.log")
        run(pipeline(`nohup julia $script_file`, stdout=log_file, stderr=log_file), wait=false)
    end

    # Wait a moment for server to start
    sleep(2)

    if is_server_running(port)
        pid = get_server_pid(port)
        @info "Background proxy server started" port = port pid = pid
    else
        @error "Failed to start background proxy server"
    end

    return nothing
end

"""
    stop_server(port::Int=3000)

Stop the proxy server running on the specified port.
"""
function stop_server(port::Int=3000)
    if SERVER[] !== nothing
        # Stop server in current process
        @info "Stopping proxy server"
        close(SERVER[])
        SERVER[] = nothing
        remove_pid_file(port)
    else
        # Try to stop background server
        pid = get_server_pid(port)
        if pid !== nothing
            @info "Stopping background proxy server" pid = pid
            if Sys.iswindows()
                run(`taskkill /PID $pid /F`, wait=false)
            else
                run(`kill $pid`, wait=false)
            end
            remove_pid_file(port)
        else
            @warn "No proxy server found on port $port"
        end
    end
end

end # module Proxy
