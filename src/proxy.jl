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
using Logging
using LoggingExtras

include("dashboard.jl")
using .Dashboard

function setup_proxy_logging(port::Int)
    cache_dir = get(ENV, "XDG_CACHE_HOME") do
        if Sys.iswindows()
            joinpath(ENV["LOCALAPPDATA"], "MCPRepl")
        else
            joinpath(homedir(), ".cache", "mcprepl")
        end
    end
    mkpath(cache_dir)

    log_file = joinpath(cache_dir, "proxy-$port.log")

    # Use FileLogger with automatic flushing
    logger = LoggingExtras.FileLogger(log_file; append=true, always_flush=true)
    global_logger(logger)

    @info "Proxy logging initialized" log_file = log_file
    return log_file
end

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
const VITE_DEV_PROCESS = Ref{Union{Base.Process,Nothing}}(nothing)
const VITE_DEV_PORT = 3001

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
# Vite Dev Server Management
# ============================================================================

"""
    is_dev_environment() -> Bool

Check if we're in a development environment (dashboard-ui source exists).
"""
function is_dev_environment()
    dashboard_src = joinpath(dirname(dirname(@__FILE__)), "dashboard-ui", "src")
    return isdir(dashboard_src)
end

"""
    is_vite_running() -> Bool

Check if Vite dev server is running on port 3001.
"""
function is_vite_running()
    try
        sock = connect("localhost", VITE_DEV_PORT)
        close(sock)
        return true
    catch
        return false
    end
end

"""
    start_vite_dev_server()

Start the Vite dev server if in development mode and not already running.
"""
function start_vite_dev_server()
    # Only start in dev environment
    if !is_dev_environment()
        @debug "Not in dev environment, skipping Vite dev server"
        return nothing
    end

    # Check if already running
    if is_vite_running()
        @info "Vite dev server already running on port $VITE_DEV_PORT"
        return nothing
    end

    # Check if process reference exists and is still running
    if VITE_DEV_PROCESS[] !== nothing && process_running(VITE_DEV_PROCESS[])
        @info "Vite dev server process already started"
        return VITE_DEV_PROCESS[]
    end

    dashboard_dir = joinpath(dirname(dirname(@__FILE__)), "dashboard-ui")

    # Check if node_modules exists
    if !isdir(joinpath(dashboard_dir, "node_modules"))
        @warn "dashboard-ui/node_modules not found. Run 'npm install' first."
        return nothing
    end

    @info "Starting Vite dev server..." dashboard_dir = dashboard_dir port = VITE_DEV_PORT

    try
        # Start npm run dev in the background
        # Need to change directory before running
        proc = cd(dashboard_dir) do
            run(pipeline(`npm run dev`, stdout=devnull, stderr=devnull), wait=false)
        end

        VITE_DEV_PROCESS[] = proc

        # Give it a moment to start
        sleep(2)

        if is_vite_running()
            @info "✅ Vite dev server started on port $VITE_DEV_PORT"
            return proc
        else
            @warn "Vite dev server may not have started successfully"
            return proc
        end
    catch e
        @error "Failed to start Vite dev server" exception = (e, catch_backtrace())
        return nothing
    end
end

"""
    stop_vite_dev_server()

Stop the Vite dev server if it's running.
"""
function stop_vite_dev_server()
    if VITE_DEV_PROCESS[] !== nothing
        try
            kill(VITE_DEV_PROCESS[])
            @info "Vite dev server stopped"
        catch e
            @debug "Error stopping Vite dev server" exception = (e, catch_backtrace())
        end
        VITE_DEV_PROCESS[] = nothing
    end
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

        # Log registration event to dashboard
        Dashboard.log_event(id, Dashboard.AGENT_START, Dict(
            "port" => port,
            "pid" => pid,
            "metadata" => metadata
        ))
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

            # Log stop event to dashboard
            Dashboard.log_event(id, Dashboard.AGENT_STOP, Dict())
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
    route_to_repl_streaming(request::Dict, original_req::HTTP.Request, http::HTTP.Stream) -> Nothing

Route a request to the appropriate backend REPL with streaming support.

Uses the X-MCPRepl-Target header to determine which REPL to route to.
If no header is present, routes to the first available REPL.
"""
function route_to_repl_streaming(request::Dict, original_req::HTTP.Request, http::HTTP.Stream)
    # Determine target REPL
    header_value = HTTP.header(original_req, "X-MCPRepl-Target")
    # HTTP.header returns a SubString{String} or String
    target_id = isempty(header_value) ? nothing : String(header_value)

    if target_id === nothing
        # No target specified - try to infer from context
        repls = list_repls()
        if isempty(repls)
            HTTP.setstatus(http, 503)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "error" => Dict(
                    "code" => -32001,
                    "message" => "No REPLs registered with proxy. Please start a REPL with MCPRepl.start!()"
                )
            )))
            return nothing
        end
        
        # Smart routing: Prefer MCPRepl agent if available
        # This prioritizes the main development REPL over test/temporary instances
        mcprepl_idx = findfirst(r -> r.id == "MCPRepl", repls)
        if mcprepl_idx !== nothing
            target_id = repls[mcprepl_idx].id
        else
            # Fall back to first available REPL
            target_id = first(repls).id
        end
    end

    # Get the REPL connection
    repl = get_repl(target_id)

    if repl === nothing
        HTTP.setstatus(http, 404)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(http, JSON.json(Dict(
            "jsonrpc" => "2.0",
            "id" => get(request, "id", nothing),
            "error" => Dict(
                "code" => -32002,
                "message" => "REPL not found: $target_id"
            )
        )))
        return nothing
    end

    if repl.status != :ready
        # If stopped, try one recovery attempt by marking as ready
        # (maybe the REPL recovered but we didn't know)
        if repl.status == :stopped
            @info "Attempting recovery for stopped REPL" id = target_id
            update_repl_status(target_id, :ready)
            repl = get_repl(target_id)
            if repl === nothing || repl.status != :ready
                HTTP.setstatus(http, 503)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32003,
                        "message" => "REPL not ready: $(repl.status)"
                    )
                )))
                return nothing
            end
        else
            HTTP.setstatus(http, 503)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "error" => Dict(
                    "code" => -32003,
                    "message" => "REPL not ready: $(repl.status)"
                )
            )))
            return nothing
        end
    end

    # Forward request to backend REPL with streaming support
    try
        backend_url = "http://127.0.0.1:$(repl.port)/"
        body_str = JSON.json(request)

        @debug "Forwarding to backend" url = backend_url body_length = length(body_str)

        # Log tool call event to dashboard
        method = get(request, "method", "")
        if method == "tools/call"
            params = get(request, "params", Dict())
            tool_name = get(params, "name", "unknown")
            tool_args = get(params, "arguments", Dict())
            Dashboard.log_event(target_id, Dashboard.TOOL_CALL, Dict(
                "tool" => tool_name,
                "method" => method,
                "arguments" => tool_args
            ))
        elseif !isempty(method)
            # Log other methods as code execution
            Dashboard.log_event(target_id, Dashboard.CODE_EXECUTION, Dict(
                "method" => method
            ))
        end

        start_time = time()
        @info "Sending request to backend" url = backend_url method = method body_length = length(body_str)

        # Make request to backend - use simple HTTP.request with response streaming disabled
        backend_response = HTTP.request(
            "POST",
            backend_url,
            ["Content-Type" => "application/json"],
            body_str;
            readtimeout=30,
            connect_timeout=5,
            status_exception=false
        )

        duration_ms = (time() - start_time) * 1000
        response_body = String(backend_response.body)
        response_status = backend_response.status
        response_headers = Dict{String,String}()
        for (name, value) in backend_response.headers
            response_headers[name] = value
        end

        @info "Received response from backend" status = response_status body_length = length(response_body)

        # Parse response to extract result/error for dashboard
        response_data = Dict("status" => response_status[], "method" => method)
        try
            response_json = JSON.parse(response_body)
            # Include the actual result or error in the event log
            if haskey(response_json, "result")
                response_data["result"] = response_json["result"]
            elseif haskey(response_json, "error")
                response_data["error"] = response_json["error"]
            end
        catch parse_err
            # If we can't parse the response, just log the status
            @debug "Could not parse response for logging" exception = parse_err
        end

        # Log successful execution with result
        Dashboard.log_event(target_id, Dashboard.OUTPUT, response_data; duration_ms=duration_ms)

        # Update last heartbeat
        update_repl_status(target_id, :ready)

        # Forward response to client with proper headers
        @info "Returning response to client" status = response_status body_length = length(response_body)
        HTTP.setstatus(http, response_status)

        # Forward all headers from backend, ensuring Content-Type is set
        for (name, value) in response_headers
            HTTP.setheader(http, name => value)
        end
        # Ensure Content-Type is set if not already present
        if !haskey(response_headers, "Content-Type")
            HTTP.setheader(http, "Content-Type" => "application/json")
        end

        HTTP.startwrite(http)
        write(http, response_body)
        return nothing
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

        # Log error event
        Dashboard.log_event(target_id, Dashboard.ERROR, Dict(
            "message" => sprint(showerror, e),
            "method" => get(request, "method", "")
        ))

        HTTP.setstatus(http, 502)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(http, JSON.json(Dict(
            "jsonrpc" => "2.0",
            "id" => get(request, "id", nothing),
            "error" => Dict(
                "code" => -32004,
                "message" => "Failed to connect to REPL: $(sprint(showerror, e))"
            )
        )))
        return nothing
    end
end

"""
    handle_request(http::HTTP.Stream) -> Nothing

Handle incoming MCP requests with streaming support. Routes to appropriate backend REPL or handles proxy commands.
"""
function handle_request(http::HTTP.Stream)
    req = http.message

    try
        # Read the full request body FIRST (required by HTTP.jl before writing response)
        body = String(read(http))

        # Log all incoming requests for debugging
        @info "Incoming request" method = req.method target = req.target content_length = length(body)

        # Handle dashboard HTTP routes
        uri = HTTP.URI(req.target)
        path = uri.path

        # Redirect /dashboard to /dashboard/ (Vite expects trailing slash)
        if path == "/dashboard"
            HTTP.setstatus(http, 301)
            HTTP.setheader(http, "Location" => "/dashboard/")
            HTTP.startwrite(http)
            return nothing
        end

        # Dashboard HTML page and static assets (React build or Vite dev server)
        if (path == "/dashboard/" || startswith(path, "/dashboard/")) && !startswith(path, "/dashboard/api/")
            # Try to proxy to Vite dev server first (for HMR during development)
            vite_port = 3001
            try
                # Quick check if Vite dev server is running
                test_conn = Sockets.connect("localhost", vite_port)
                close(test_conn)

                # Vite is running - proxy the request to it
                # Keep the full path including /dashboard since Vite is configured with base: '/dashboard/'
                vite_url = "http://localhost:$(vite_port)$(path)"
                vite_response = HTTP.get(vite_url, status_exception=false)

                HTTP.setstatus(http, vite_response.status)
                for (name, value) in vite_response.headers
                    # Skip transfer-encoding headers that HTTP.jl handles
                    if lowercase(name) ∉ ["transfer-encoding", "connection"]
                        HTTP.setheader(http, name => value)
                    end
                end
                HTTP.startwrite(http)
                write(http, vite_response.body)
                return nothing
            catch e
                # Vite not running - fall back to serving built static files
                asset_path = replace(path, r"^/dashboard/" => "")
                response = Dashboard.serve_static_file(asset_path)
                HTTP.setstatus(http, response.status)
                for (name, value) in response.headers
                    HTTP.setheader(http, name => value)
                end
                HTTP.startwrite(http)
                write(http, response.body)
                return nothing
            end
        end        # Dashboard API: Get all agents
        if path == "/dashboard/api/agents"
            agents = Dict{String,Any}()
            for (id, conn) in REPL_REGISTRY
                agents[id] = Dict(
                    "id" => id,
                    "port" => conn.port,
                    "pid" => conn.pid,
                    "status" => string(conn.status),
                    "last_heartbeat" => Dates.format(conn.last_heartbeat, "yyyy-mm-dd HH:MM:SS")
                )
            end
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(agents))
            return nothing
        end

        # Dashboard API: Get events
        if path == "/dashboard/api/events"
            query_params = HTTP.queryparams(uri)
            id = get(query_params, "id", nothing)
            limit = parse(Int, get(query_params, "limit", "100"))

            events = Dashboard.get_events(id=id, limit=limit)
            events_json = [Dict(
                "id" => e.id,
                "type" => string(e.event_type),
                "timestamp" => Dates.format(e.timestamp, "yyyy-mm-dd HH:MM:SS.sss"),
                "data" => e.data,
                "duration_ms" => e.duration_ms
            ) for e in events]

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(events_json))
            return nothing
        end

        # Dashboard API: Server-Sent Events stream
        if path == "/dashboard/api/events/stream"
            query_params = HTTP.queryparams(uri)
            id = get(query_params, "id", nothing)
            
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/event-stream")
            HTTP.setheader(http, "Cache-Control" => "no-cache")
            HTTP.setheader(http, "Connection" => "keep-alive")
            HTTP.startwrite(http)
            
            # Send initial connection event
            write(http, "event: connected\n")
            write(http, "data: {\"status\":\"connected\"}\n\n")
            flush(http)
            
            # Track last seen event ID to only send new events
            last_event_time = now()
            
            try
                while isopen(http)
                    # Get events since last check
                    events = Dashboard.get_events(id=id, limit=50)
                    new_events = filter(e -> e.timestamp > last_event_time, events)
                    
                    for event in new_events
                        event_data = Dict(
                            "id" => event.id,
                            "type" => string(event.event_type),
                            "timestamp" => Dates.format(event.timestamp, "yyyy-mm-dd HH:MM:SS.sss"),
                            "data" => event.data,
                            "duration_ms" => event.duration_ms
                        )
                        
                        write(http, "event: update\n")
                        write(http, "data: $(JSON.json(event_data))\n\n")
                        flush(http)
                        
                        last_event_time = max(last_event_time, event.timestamp)
                    end
                    
                    # Wait before next poll
                    sleep(0.5)
                end
            catch e
                if !(e isa Base.IOError)
                    @debug "SSE stream error" exception=e
                end
            end
            
            return nothing
        end

        # Dashboard WebSocket (for future implementation)
        if path == "/dashboard/ws"
            HTTP.setstatus(http, 501)
            HTTP.setheader(http, "Content-Type" => "text/plain")
            HTTP.startwrite(http)
            write(http, "WebSocket not yet implemented")
            return nothing
        end

        @info "Checking if body is empty" is_empty = isempty(body)
        if isempty(body)
            @info "Body IS empty - handling empty body case"
            # Handle OPTIONS requests (CORS preflight for streamable-http)
            if req.method == "OPTIONS"
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Access-Control-Allow-Origin" => "*")
                HTTP.setheader(http, "Access-Control-Allow-Methods" => "GET, POST, OPTIONS")
                HTTP.setheader(http, "Access-Control-Allow-Headers" => "Content-Type, Authorization")
                HTTP.setheader(http, "Access-Control-Max-Age" => "86400")
                HTTP.setheader(http, "Content-Length" => "0")
                HTTP.startwrite(http)
                return nothing
            end

            # Handle GET requests (health checks, metadata)
            if req.method == "GET"
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "status" => "ok",
                    "type" => "mcprepl-proxy",
                    "version" => "0.1.0",
                    "pid" => getpid(),
                    "uptime" => time(),
                    "protocol" => "MCP 2024-11-05"
                )))
                return nothing
            end
            # Empty POST body - invalid request
            HTTP.setstatus(http, 400)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "error" => Dict(
                    "code" => -32700,
                    "message" => "Parse error: empty request body"
                ),
                "id" => nothing
            )))
            return nothing
        end

        # Parse JSON-RPC request
        request = JSON.parse(body)

        # Log all incoming requests with full details
        method = get(request, "method", "")
        request_id = get(request, "id", nothing)
        params = get(request, "params", nothing)
        @info "📨 MCP Request" method = method id = request_id has_params = !isnothing(params)

        if method == "proxy/status"
            repls = list_repls()
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
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
            return nothing
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
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32602,
                        "message" => "Invalid params: 'id' and 'port' are required"
                    )
                )))
                return nothing
            end

            register_repl(id, port; pid=pid, metadata=metadata)

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict("status" => "registered", "id" => id)
            )))
            return nothing
        elseif method == "proxy/unregister"
            # Unregister a REPL
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32602,
                        "message" => "Invalid params: 'id' is required"
                    )
                )))
                return nothing
            end

            unregister_repl(id)

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict("status" => "unregistered", "id" => id)
            )))
            return nothing
        elseif method == "proxy/heartbeat"
            # REPL sends heartbeat to indicate it's alive
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32602,
                        "message" => "Invalid params: 'id' is required"
                    )
                )))
                return nothing
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

                    # Log heartbeat event (don't spam - could be rate limited in Dashboard module)
                    Dashboard.log_event(id, Dashboard.HEARTBEAT, Dict("status" => "ok"))
                end
            end

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict("status" => "ok")
            )))
            return nothing
        elseif method == "initialize"
            # Handle MCP initialize request
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict(
                    "protocolVersion" => "2024-11-05",
                    "capabilities" => Dict(
                        "tools" => Dict()
                    ),
                    "serverInfo" => Dict(
                        "name" => "mcprepl-proxy",
                        "version" => "0.1.0"
                    )
                )
            )))
            return nothing
        elseif method == "tools/list"
            # Always include proxy management tools, plus backend tools if available
            repls = list_repls()
            @info "tools/list handling" num_repls = length(repls) repl_ids = [r.id for r in repls]

            # Start with proxy tools (always available)
            proxy_tools = [
                Dict(
                    "name" => "proxy_status",
                    "description" => "Get the status of the MCP proxy server and connected REPL backends",
                    "inputSchema" => Dict(
                        "type" => "object",
                        "properties" => Dict(),
                        "required" => []
                    )
                ),
                Dict(
                    "name" => "list_agents",
                    "description" => "List all registered REPL agents and their connection status",
                    "inputSchema" => Dict(
                        "type" => "object",
                        "properties" => Dict(),
                        "required" => []
                    )
                ),
                Dict(
                    "name" => "dashboard_url",
                    "description" => "Get the URL to access the monitoring dashboard",
                    "inputSchema" => Dict(
                        "type" => "object",
                        "properties" => Dict(),
                        "required" => []
                    )
                ),
                Dict(
                    "name" => "start_agent",
                    "description" => "Start a new Julia REPL agent process for a specific project. The agent will register with the proxy and be available for tool calls.",
                    "inputSchema" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "project_path" => Dict(
                                "type" => "string",
                                "description" => "Path to the Julia project directory (containing Project.toml)"
                            ),
                            "agent_name" => Dict(
                                "type" => "string",
                                "description" => "Optional name for the agent (defaults to project directory name)"
                            )
                        ),
                        "required" => ["project_path"]
                    )
                )
            ]

            if isempty(repls)
                # No backends - return only proxy tools
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "result" => Dict("tools" => proxy_tools)
                )))
                return nothing
            else
                # Fetch backend tools and combine with proxy tools
                # Forward request to first available backend
                request_dict = request isa Dict ? request : Dict(String(k) => v for (k, v) in pairs(request))
                target_id = first(repls).id
                repl = get_repl(target_id)

                if repl !== nothing && repl.status == :ready
                    # Try to get tools from backend
                    try
                        backend_url = "http://127.0.0.1:$(repl.port)/"
                        body_str = JSON.json(request)
                        backend_response = HTTP.request(
                            "POST",
                            backend_url,
                            ["Content-Type" => "application/json"],
                            body_str;
                            readtimeout=5,
                            connect_timeout=2,
                            status_exception=false
                        )

                        if backend_response.status == 200
                            backend_data = JSON.parse(String(backend_response.body))
                            if haskey(backend_data, "result") && haskey(backend_data["result"], "tools")
                                # Combine proxy tools + backend tools
                                all_tools = vcat(proxy_tools, backend_data["result"]["tools"])
                                HTTP.setstatus(http, 200)
                                HTTP.setheader(http, "Content-Type" => "application/json")
                                HTTP.startwrite(http)
                                write(http, JSON.json(Dict(
                                    "jsonrpc" => "2.0",
                                    "id" => get(request, "id", nothing),
                                    "result" => Dict("tools" => all_tools)
                                )))
                                return nothing
                            end
                        end
                    catch e
                        @warn "Failed to fetch backend tools, returning proxy tools only" exception = e
                    end
                end

                # Fallback: return only proxy tools if backend fetch failed
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "result" => Dict("tools" => proxy_tools)
                )))
                return nothing
            end
        elseif method == "tools/call"
            # Handle proxy-level tools (always available)
            params = get(request, "params", Dict())
            tool_name = get(params, "name", "")
            repls = list_repls()
            num_repls = length(repls)

            if tool_name == "proxy_status"
                status_text = "MCP Proxy Status:\n- Port: 3000\n- Connected agents: $num_repls\n- Status: Running\n- Dashboard: http://localhost:3001"
                if num_repls == 0
                    status_text *= "\n\nNo backend REPL agents are currently connected. Start a backend REPL to enable Julia tools."
                else
                    status_text *= "\n\nConnected agents:\n"
                    for repl in repls
                        status_text *= "  - $(repl.id) (port $(repl.port), status: $(repl.status))\n"
                    end
                end
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "result" => Dict(
                        "content" => [Dict(
                            "type" => "text",
                            "text" => status_text
                        )]
                    )
                )))
                return nothing
            elseif tool_name == "list_agents"
                if isempty(repls)
                    agent_text = "No REPL agents currently registered.\n\nTo connect a backend REPL:\n1. Start a Julia REPL with MCPRepl\n2. It will automatically register with this proxy\n3. Julia tools will become available"
                else
                    agent_text = "Connected REPL agents ($num_repls):\n\n"
                    for repl in repls
                        pid_str = repl.pid === nothing ? "N/A" : string(repl.pid)
                        agent_text *= "**$(repl.id)**\n"
                        agent_text *= "  - Port: $(repl.port)\n"
                        agent_text *= "  - PID: $pid_str\n"
                        agent_text *= "  - Status: $(repl.status)\n"
                        agent_text *= "  - Last heartbeat: $(repl.last_heartbeat)\n\n"
                    end
                end
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "result" => Dict(
                        "content" => [Dict(
                            "type" => "text",
                            "text" => agent_text
                        )]
                    )
                )))
                return nothing
            elseif tool_name == "dashboard_url"
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "result" => Dict(
                        "content" => [Dict(
                            "type" => "text",
                            "text" => "Dashboard URL: http://localhost:3001\n\nThe dashboard provides real-time monitoring of:\n- Connected REPL agents\n- Tool calls and code execution\n- Event logs and metrics\n- Agent status and heartbeats"
                        )]
                    )
                )))
                return nothing
            elseif tool_name == "start_agent"
                # Parse arguments
                project_path = get(args, "project_path", "")
                agent_name = get(args, "agent_name", basename(project_path))
                
                if isempty(project_path)
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "project_path is required"
                        )
                    )))
                    return nothing
                end
                
                # Check if agent already exists
                existing = findfirst(r -> r.id == agent_name, repls)
                if existing !== nothing
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict(
                            "content" => [Dict(
                                "type" => "text",
                                "text" => "Agent '$agent_name' is already running on port $(repls[existing].port)"
                            )]
                        )
                    )))
                    return nothing
                end
                
                # Spawn new Julia REPL process
                try
                    julia_cmd = `julia --project=$project_path -e "using MCPRepl; MCPRepl.start!(agent_name=\"$agent_name\")"`
                    
                    # Run in background
                    proc = run(pipeline(julia_cmd, stdout=devnull, stderr=devnull), wait=false)
                    
                    # Wait for agent to register (max 10 seconds)
                    registered = false
                    for i in 1:100
                        sleep(0.1)
                        idx = findfirst(r -> r.id == agent_name, repls)
                        if idx !== nothing
                            registered = true
                            new_agent = repls[idx]
                            HTTP.setstatus(http, 200)
                            HTTP.setheader(http, "Content-Type" => "application/json")
                            HTTP.startwrite(http)
                            write(http, JSON.json(Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "result" => Dict(
                                    "content" => [Dict(
                                        "type" => "text",
                                        "text" => "Successfully started agent '$agent_name' on port $(new_agent.port)\n\nProject: $project_path\nPID: $(new_agent.pid)\nStatus: $(new_agent.status)"
                                    )]
                                )
                            )))
                            return nothing
                        end
                    end
                    
                    # Timeout
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Agent process started but did not register within 10 seconds. Check logs for details."
                        )
                    )))
                    return nothing
                catch e
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32603,
                            "message" => "Failed to start agent: $(sprint(showerror, e))"
                        )
                    )))
                    return nothing
                end
            else
                # Tool requires backend REPL - check if any are available
                if isempty(repls)
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict(
                            "content" => [Dict(
                                "type" => "text",
                                "text" => "⚠️ Tool '$tool_name' requires a Julia REPL backend.\n\nNo REPL agents are currently connected to the proxy.\n\nTo enable Julia tools:\n1. Start a Julia REPL\n2. Run: using MCPRepl; MCPRepl.start!()\n3. The REPL will automatically register with this proxy\n\nAvailable proxy tools: proxy_status, list_agents, dashboard_url"
                            )]
                        )
                    )))
                    return nothing
                else
                    # Route to backend
                    request_dict = request isa Dict ? request : Dict(String(k) => v for (k, v) in pairs(request))
                    route_to_repl_streaming(request_dict, req, http)
                    return nothing
                end
            end
        else
            # Unknown method - route to backend if available
            repls = list_repls()
            if isempty(repls)
                # No backends available - return a friendly message
                @info "No backends available for method" method = method
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "result" => nothing  # Many MCP methods (like notifications) expect null result
                )))
                return nothing
            else
                # Route to backend REPL
                request_dict = request isa Dict ? request : Dict(String(k) => v for (k, v) in pairs(request))
                route_to_repl_streaming(request_dict, req, http)
                return nothing
            end
        end

    catch e
        @error "Error handling request" exception = (e, catch_backtrace())
        HTTP.setstatus(http, 500)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(http, JSON.json(Dict(
            "jsonrpc" => "2.0",
            "error" => Dict(
                "code" => -32603,
                "message" => "Internal error: $(sprint(showerror, e))"
            ),
            "id" => nothing
        )))
        return nothing
    end
end

"""
    start_server(port::Int=3000; background::Bool=false, status_callback=nothing) -> Union{HTTP.Server, Nothing}

Start the persistent MCP proxy server.

# Arguments
- `port::Int=3000`: Port to listen on
- `background::Bool=false`: If true, run in background process
- `status_callback`: Optional function to call with status updates (for background mode)

# Returns
- HTTP.Server if running in foreground
- nothing if started in background
"""
function start_server(port::Int=3000; background::Bool=false, status_callback=nothing)
    if is_server_running(port)
        existing_pid = get_server_pid(port)
        if existing_pid !== nothing
            @info "Proxy server already running on port $port (PID: $existing_pid)"
            return nothing
        end
    end

    if background
        # Start server in background process
        return start_background_server(port; status_callback=status_callback)
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

    # Set up file logging
    log_file = setup_proxy_logging(port)
    println("Proxy log file: $log_file")

    @info "Starting MCP Proxy Server" port = port pid = getpid()

    # Start Vite dev server if in development mode
    start_vite_dev_server()

    # Setup cleanup on exit
    atexit(() -> begin
        stop_vite_dev_server()
        remove_pid_file(port)
    end)

    # Start HTTP server with streaming support
    server = HTTP.serve!(handle_request, ip"127.0.0.1", port; verbose=false, stream=true)
    SERVER[] = server

    @info "MCP Proxy Server started successfully" port = port pid = getpid()

    return server
end

"""
    start_background_server(port::Int=3000; status_callback=nothing) -> Nothing

Start the proxy server in a detached background process.

If `status_callback` is provided, it will be called with status updates instead of
printing directly (useful when parent has its own spinner).
"""
function start_background_server(port::Int=3000; status_callback=nothing)
    # Create a Julia script that starts the server
    script = """
    using Pkg
    Pkg.activate("$(Base.active_project())")

    using MCPRepl

    println("Starting MCP Proxy Server in background...")
    MCPRepl.Proxy.start_foreground_server($port)

    # Keep server running
    println("Press Ctrl+C to stop the server")
    try
        wait(MCPRepl.Proxy.SERVER[])
    catch e
        @warn "Server stopped" exception=e
    end
    """

    script_file = tempname() * ".jl"
    write(script_file, script)

    # Start detached Julia process
    @debug "Launching background proxy server" port = port

    if Sys.iswindows()
        # Windows: use START command
        run(`cmd /c start julia $script_file`, wait=false)
    else
        # Unix: use nohup and redirect output
        log_file = joinpath(dirname(get_pid_file_path(port)), "proxy-$port-background.log")
        run(pipeline(`nohup julia $script_file`, stdout=log_file, stderr=log_file), wait=false)
    end

    # Wait for server to start
    max_wait = 30  # seconds
    elapsed = 0.0
    check_interval = 0.1  # Check every 100ms

    while elapsed < max_wait
        # Update status via callback if provided, otherwise print directly
        if status_callback !== nothing
            elapsed_sec = round(Int, elapsed)
            # Color the number with coral/salmon (203 = coral pink)
            status_callback("Starting MCPRepl (waiting for proxy server... \033[38;5;203m$(elapsed_sec)s\033[0m)")
        end

        if is_server_running(port)
            # Success
            if status_callback !== nothing
                status_callback("Starting MCPRepl (proxy server ready)")
            end
            pid = get_server_pid(port)
            @debug "Background proxy server started" port = port pid = pid elapsed_time = elapsed
            return nothing
        end

        sleep(check_interval)
        elapsed += check_interval
    end

    # Server didn't start in time
    @error "Failed to start background proxy server" timeout = max_wait

    # Show log contents to help debug
    background_log = joinpath(dirname(get_pid_file_path(port)), "proxy-$port-background.log")
    if isfile(background_log)
        log_contents = read(background_log, String)
        if !isempty(log_contents)
            @error "Background server log:" log = log_contents
        end
    end

    return nothing
end

"""
    stop_server(port::Int=3000)

Stop the proxy server running on the specified port.
"""
function stop_server(port::Int=3000)
    # Stop Vite dev server first
    stop_vite_dev_server()

    if SERVER[] !== nothing
        # Stop server in current process
        @info "Stopping proxy server"
        close(SERVER[])
        SERVER[] = nothing
        remove_pid_file(port)
    else
        # Try to stop background server by PID file
        pid = get_server_pid(port)
        if pid !== nothing
            @info "Stopping background proxy server" pid = pid
            if Sys.iswindows()
                run(`taskkill /PID $pid /F`, wait=false)
            else
                run(`kill $pid`, wait=false)
            end
            remove_pid_file(port)
        end

        # Also kill any process listening on the port (in case PID file is stale)
        try
            if !Sys.iswindows()
                # Use lsof to find and kill any process on the port
                result = read(`lsof -ti :$port`, String)
                pids = split(strip(result), '\n')
                for pid_str in pids
                    if !isempty(pid_str)
                        pid_num = parse(Int, pid_str)
                        @info "Killing process on port $port" pid = pid_num
                        run(`kill $pid_num`, wait=false)
                    end
                end
            end
        catch e
            # Port might not be in use, that's okay
            @debug "No additional processes found on port $port"
        end

        if pid === nothing && !is_server_running(port)
            @info "No proxy server found on port $port"
        end
    end
end

"""
    restart_server(port::Int=3000; background::Bool=false)

Restart the proxy server (stop existing if running, then start new).

# Arguments
- `port::Int=3000`: Port to listen on
- `background::Bool=false`: If true, run in background process

# Returns
- HTTP.Server if running in foreground
- nothing if started in background
"""
function restart_server(port::Int=3000; background::Bool=false)
    # Stop existing server if running (won't error if not running)
    if is_server_running(port)
        @info "Stopping existing proxy server on port $port"
        stop_server(port)
        sleep(1)  # Give it time to shutdown
    end

    # Start new server
    @info "Starting proxy server on port $port"
    return start_server(port; background=background)
end

end # module Proxy
