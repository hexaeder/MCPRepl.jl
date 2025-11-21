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
        # No target specified, try to use first available REPL
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
        target_id = first(repls).id
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

        # Dashboard HTML page
        if path == "/dashboard" || path == "/dashboard/"
            html = Dashboard.dashboard_html()
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/html")
            HTTP.startwrite(http)
            write(http, html)
            return nothing
        end

        # Dashboard static assets (React build)
        if startswith(path, "/dashboard/") && !startswith(path, "/dashboard/api/")
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

        # Dashboard API: Get all agents
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

        @info "Body is NOT empty - proceeding to parse JSON"
        # Parse JSON-RPC request
        @info "About to parse JSON" body_length = length(body)
        request = JSON.parse(body)
        @info "Parsed JSON request"

        # Handle proxy-specific methods
        method = get(request, "method", "")
        @info "Handling method" method = method

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

    # Set up file logging
    log_file = setup_proxy_logging(port)
    println("Proxy log file: $log_file")

    @info "Starting MCP Proxy Server" port = port pid = getpid()

    # Setup cleanup on exit
    atexit(() -> remove_pid_file(port))

    # Start HTTP server with streaming support
    server = HTTP.serve!(handle_request, ip"127.0.0.1", port; verbose=false, stream=true)
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
