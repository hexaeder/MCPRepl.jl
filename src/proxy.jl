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
using Dates: Minute, Second
using Logging
using LoggingExtras
using UUIDs

include("dashboard.jl")
using .Dashboard

include("session.jl")
using .Session

include("proxy_tools.jl")

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
    status::Symbol                      # :ready, :disconnected, :reconnecting, :stopped
    last_heartbeat::DateTime            # Last time we heard from this REPL
    metadata::Dict{String,Any}         # Additional info (project path, etc.)
    last_error::Union{String,Nothing}  # Last error message if any
    missed_heartbeats::Int             # Counter for consecutive missed heartbeats
    pending_requests::Vector{Tuple{Dict,HTTP.Stream}}  # Buffered requests during reconnection
    disconnect_time::Union{DateTime,Nothing}  # When REPL disconnected
end

# Global state
const SERVER = Ref{Union{HTTP.Server,Nothing}}(nothing)
const SERVER_PORT = Ref{Int}(3000)
const SERVER_PID_FILE = Ref{String}("")
const REPL_REGISTRY = Dict{String,REPLConnection}()
const REPL_REGISTRY_LOCK = ReentrantLock()
const SESSION_REGISTRY = Dict{String,MCPSession}()  # Track MCP client sessions
const SESSION_LOCK = ReentrantLock()
const CLIENT_CONNECTIONS = Dict{String,Channel{Dict}}()  # Track active client notification channels
const CLIENT_CONNECTIONS_LOCK = ReentrantLock()
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
# MCP Notification Support
# ============================================================================

"""
    notify_tools_list_changed()

Send notifications/tools/list_changed to all connected MCP clients.
This tells clients to refresh their tools list after a Julia session registers.
"""
function notify_tools_list_changed()
    @info "Broadcasting tools/list_changed notification to all connected clients"

    notification = Dict(
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed",
        "params" => Dict(),
    )

    # Send notification to all active client connections
    lock(CLIENT_CONNECTIONS_LOCK) do
        for (session_id, channel) in CLIENT_CONNECTIONS
            try
                # Non-blocking put - if channel is full, skip this client
                if isopen(channel) && length(channel.data) < 10
                    put!(channel, notification)
                    @debug "Sent notification to client" session_id = session_id
                end
            catch e
                @debug "Failed to send notification to client" session_id = session_id error =
                    e
            end
        end
    end
end

"""
    register_client_connection(session_id::String) -> Channel{Dict}

Register a new client connection and return a channel for sending notifications.
"""
function register_client_connection(session_id::String)
    channel = Channel{Dict}(32)  # Buffer up to 32 notifications

    lock(CLIENT_CONNECTIONS_LOCK) do
        CLIENT_CONNECTIONS[session_id] = channel
    end

    @debug "Registered client connection" session_id = session_id
    return channel
end

"""
    unregister_client_connection(session_id::String)

Remove a client connection when the session ends.
"""
function unregister_client_connection(session_id::String)
    lock(CLIENT_CONNECTIONS_LOCK) do
        if haskey(CLIENT_CONNECTIONS, session_id)
            channel = CLIENT_CONNECTIONS[session_id]
            close(channel)
            delete!(CLIENT_CONNECTIONS, session_id)
            @debug "Unregistered client connection" session_id = session_id
        end
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
function register_repl(
    id::String,
    port::Int;
    pid::Union{Int,Nothing}=nothing,
    metadata::Dict=Dict(),
)
    # Check for pending requests and copy them outside the lock
    pending = lock(REPL_REGISTRY_LOCK) do
        # Check if this is a re-registration (reconnection)
        existing = get(REPL_REGISTRY, id, nothing)
        pending_requests =
            existing !== nothing ? existing.pending_requests : Tuple{Dict,HTTP.Stream}[]

        if existing !== nothing && !isempty(pending_requests)
            @info "REPL re-registering with buffered requests" id = id port = port pid = pid buffer_size = length(pending_requests)
        end

        REPL_REGISTRY[id] = REPLConnection(
            id,
            port,
            pid,
            :ready,
            now(),
            metadata,
            nothing,
            0,
            Tuple{Dict,HTTP.Stream}[],  # Start with empty buffer - we'll flush old requests separately
            nothing,
        )
        @info "REPL registered with proxy" id = id port = port pid = pid

        # Log registration event to dashboard
        Dashboard.log_event(
            id,
            Dashboard.AGENT_START,
            Dict("port" => port, "pid" => pid, "metadata" => metadata),
        )

        # Return pending requests to process outside the lock
        pending_requests
    end

    # If there were pending requests, flush them to the newly connected REPL
    # Do this outside the lock to avoid holding it during HTTP requests
    if !isempty(pending)
        @async flush_pending_requests(id, pending)
    end

    # Notify all connected MCP clients that tools list has changed
    notify_tools_list_changed()
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
    create_mcp_session(target_repl_id::Union{String,Nothing}) -> MCPSession

Create a new MCP session for a client connection.
"""
function create_mcp_session(target_repl_id::Union{String,Nothing})
    session = MCPSession(target_repl_id=target_repl_id)

    lock(SESSION_LOCK) do
        SESSION_REGISTRY[session.id] = session
    end

    @info "Created MCP session" session_id = session.id target_repl_id = target_repl_id
    return session
end

"""
    get_mcp_session(session_id::String) -> Union{MCPSession, Nothing}

Get an MCP session by its ID.
"""
function get_mcp_session(session_id::String)
    lock(SESSION_LOCK) do
        return get(SESSION_REGISTRY, session_id, nothing)
    end
end

"""
    delete_mcp_session!(session_id::String)

Delete an MCP session.
"""
function delete_mcp_session!(session_id::String)
    lock(SESSION_LOCK) do
        if haskey(SESSION_REGISTRY, session_id)
            session = SESSION_REGISTRY[session_id]
            close_session!(session)
            delete!(SESSION_REGISTRY, session_id)
            @info "Deleted MCP session" session_id = session_id
        end
    end
end

"""
    cleanup_inactive_sessions!(max_age::Dates.Period=Dates.Hour(1))

Remove sessions that haven't been active for longer than max_age.
"""
function cleanup_inactive_sessions!(max_age::Dates.Period=Dates.Hour(1))
    cutoff = now() - max_age
    lock(SESSION_LOCK) do
        inactive =
            [id for (id, session) in SESSION_REGISTRY if session.last_activity < cutoff]
        for id in inactive
            session = SESSION_REGISTRY[id]
            close_session!(session)
            delete!(SESSION_REGISTRY, id)
            @info "Cleaned up inactive session" session_id = id
        end
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
function update_repl_status(
    id::String,
    status::Symbol;
    error::Union{String,Nothing}=nothing,
)
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
                REPL_REGISTRY[id].disconnect_time = nothing

                # Process any pending requests if we just reconnected
                if !isempty(REPL_REGISTRY[id].pending_requests)
                    @info "REPL reconnected, processing buffered requests" id = id buffer_size =
                        length(REPL_REGISTRY[id].pending_requests)
                    @async process_pending_requests(id)
                end
            end
        end
    end
end

"""
    try_reconnect(repl_id::String)

Attempt to reconnect to a disconnected REPL by sending test requests.
"""
function try_reconnect(repl_id::String)
    max_attempts = 30  # Try for ~30 seconds
    attempt = 0

    while attempt < max_attempts
        attempt += 1
        sleep(1)  # Wait 1 second between attempts

        repl = get_repl(repl_id)
        if repl === nothing || repl.status == :stopped
            break
        end

        # Try a simple ping request
        try
            response = HTTP.request(
                "POST",
                "http://127.0.0.1:$(repl.port)/",
                ["Content-Type" => "application/json"],
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => 999999,
                        "method" => "ping",
                        "params" => Dict(),
                    ),
                );
                readtimeout=2,
                connect_timeout=2,
                status_exception=false,
            )

            if response.status == 200
                # Success! Mark as ready
                @info "REPL reconnection successful" id = repl_id attempt = attempt
                update_repl_status(repl_id, :ready)
                return
            end
        catch e
            @debug "Reconnection attempt failed" id = repl_id attempt = attempt exception =
                e
        end
    end

    # Failed to reconnect after all attempts
    @warn "Failed to reconnect to REPL after $max_attempts attempts" id = repl_id

    # Reset status back to disconnected
    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, repl_id)
            REPL_REGISTRY[repl_id].status = :disconnected
        end
    end

    flush_pending_requests_with_error(
        repl_id,
        "Reconnection timeout after $max_attempts seconds",
    )
end

"""
    process_pending_requests(repl_id::String)

Process all buffered requests for a reconnected REPL.
"""
function process_pending_requests(repl_id::String)
    pending = Tuple{Dict,HTTP.Stream}[]

    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, repl_id)
            pending = copy(REPL_REGISTRY[repl_id].pending_requests)
            empty!(REPL_REGISTRY[repl_id].pending_requests)
        end
    end

    for (request, http) in pending
        try
            # Re-route the request
            route_to_repl_streaming(request, http.message, http)
        catch e
            @error "Error processing pending request" repl_id = repl_id exception = e
        end
    end
end

"""
    flush_pending_requests_with_error(repl_id::String, error_message::String)

Send error responses to all buffered requests when REPL cannot be recovered.
"""
function flush_pending_requests_with_error(repl_id::String, error_message::String)
    pending = Tuple{Dict,HTTP.Stream}[]

    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, repl_id)
            pending = copy(REPL_REGISTRY[repl_id].pending_requests)
            empty!(REPL_REGISTRY[repl_id].pending_requests)
        end
    end

    for (request, http) in pending
        try
            HTTP.setstatus(http, 503)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32005,
                            "message" => "REPL unavailable: $error_message",
                        ),
                    ),
                ),
            )
        catch e
            @error "Error flushing pending request" repl_id = repl_id exception = e
        end
    end

    @info "Flushed pending requests with error" repl_id = repl_id count = length(pending)
end

"""
    flush_pending_requests(repl_id::String, pending::Vector{Tuple{Dict,HTTP.Stream}})

Process all buffered requests for a REPL that has reconnected.
Forwards each buffered request to the REPL and returns responses to waiting clients.
"""
function flush_pending_requests(repl_id::String, pending::Vector{Tuple{Dict,HTTP.Stream}})
    @info "Flushing buffered requests to reconnected REPL" repl_id = repl_id count =
        length(pending)

    repl = get_repl(repl_id)
    if repl === nothing
        @warn "REPL not found when flushing buffered requests" repl_id = repl_id
        return
    end

    # Execute buffered requests and forward responses to clients
    for (request, http) in pending
        try
            backend_url = "http://127.0.0.1:$(repl.port)/"
            body_str = JSON.json(request)

            @debug "Executing buffered request" repl_id = repl_id request_id =
                get(request, "id", nothing)

            # Execute the request
            backend_response = HTTP.request(
                "POST",
                backend_url,
                ["Content-Type" => "application/json"],
                body_str;
                readtimeout=30,
                connect_timeout=5,
                status_exception=false,
            )

            # Try to send response back to client if stream is still open
            if isopen(http)
                try
                    HTTP.setstatus(http, backend_response.status)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, String(backend_response.body))
                    @info "Buffered request executed and response sent to client" repl_id =
                        repl_id request_id = get(request, "id", nothing)
                catch stream_err
                    @debug "Client stream closed, response discarded" repl_id = repl_id exception =
                        stream_err
                end
            else
                @debug "Client stream already closed" repl_id = repl_id request_id =
                    get(request, "id", nothing)
            end
        catch e
            @error "Error executing buffered request" repl_id = repl_id exception = e
            # Try to send error to client
            if isopen(http)
                try
                    HTTP.setstatus(http, 500)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "error" => Dict(
                                    "code" => -32603,
                                    "message" => "Error executing buffered request: $(sprint(showerror, e))",
                                ),
                            ),
                        ),
                    )
                catch
                end
            end
        end
    end
end

"""
    send_reconnection_updates(repl_id::String, request::Dict, http::HTTP.Stream)

Send periodic status updates to client while waiting for REPL reconnection.
Returns when REPL reconnects or timeout is reached.

For the `ex` tool, sends Julia comments every 5 seconds.
For other tools, sends a space character every 15 seconds to keep TCP connection alive.
"""
function send_reconnection_updates(repl_id::String, request::Dict, http::HTTP.Stream)
    max_wait = 60  # Wait up to 60 seconds for reconnection
    start_time = time()
    update_interval = 5  # Send visible update every 5 seconds for ex tool
    keepalive_interval = 15  # Send keepalive every 15 seconds for other tools
    last_update = 0.0
    last_keepalive = 0.0

    # Get the tool being called to customize the message
    params = get(request, "params", Dict())
    tool_name = get(params, "name", "unknown")

    while time() - start_time < max_wait
        # Check if REPL has reconnected
        repl = get_repl(repl_id)
        if repl !== nothing && repl.status == :ready
            @debug "REPL reconnected, request will be processed" repl_id = repl_id
            return  # Request will be processed by flush_pending_requests
        end

        # Check if stream is still open
        if !isopen(http)
            @debug "Client disconnected while waiting for REPL" repl_id = repl_id
            return
        end

        elapsed = time() - start_time

        # Send periodic update based on tool type
        if tool_name == "ex"
            # For code execution, send informative comments
            if elapsed - last_update >= update_interval
                try
                    status_msg = "# REPL reconnecting... ($(round(Int, elapsed))s elapsed, waiting up to $(max_wait)s)\n"
                    write(http, status_msg)
                    flush(http)
                    last_update = elapsed
                    @debug "Sent reconnection update" repl_id = repl_id elapsed = elapsed
                catch e
                    @debug "Error sending update, client may have disconnected" exception =
                        e
                    return
                end
            end
        else
            # For other tools, just send periodic keepalives (spaces are ignored in JSON)
            if elapsed - last_keepalive >= keepalive_interval
                try
                    write(http, " ")  # Single space to keep connection alive
                    flush(http)
                    last_keepalive = elapsed
                    @debug "Sent keepalive" repl_id = repl_id elapsed = elapsed
                catch e
                    @debug "Error sending keepalive, client may have disconnected" exception =
                        e
                    return
                end
            end
        end

        sleep(1)
    end

    # Timeout reached - send error response
    @warn "REPL reconnection timeout" repl_id = repl_id elapsed = time() - start_time

    # Remove from pending requests buffer
    lock(REPL_REGISTRY_LOCK) do
        if haskey(REPL_REGISTRY, repl_id)
            filter!(item -> item[2] !== http, REPL_REGISTRY[repl_id].pending_requests)
        end
    end

    # Send timeout error to client if stream still open
    try
        if isopen(http)
            HTTP.setstatus(http, 503)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32005,
                            "message" => "REPL reconnection timeout after $(max_wait) seconds",
                        ),
                    ),
                ),
            )
        end
    catch e
        @debug "Error sending timeout response" exception = e
    end
end

"""
    monitor_heartbeats()

Background task that monitors REPL heartbeats and marks REPLs as disconnected if they stop responding.
Runs every 1 second and checks for REPLs that haven't sent a heartbeat in 30 seconds.
"""
function monitor_heartbeats()
    while SERVER[] !== nothing
        try
            sleep(1)  # Check every 1 second

            if SERVER[] === nothing
                break
            end

            repl_ids_to_check = String[]
            lock(REPL_REGISTRY_LOCK) do
                repl_ids_to_check = collect(keys(REPL_REGISTRY))
            end

            for repl_id in repl_ids_to_check
                # Do all checks inside lock to avoid race conditions
                lock(REPL_REGISTRY_LOCK) do
                    if !haskey(REPL_REGISTRY, repl_id)
                        return
                    end

                    repl = REPL_REGISTRY[repl_id]

                    # Skip if already disconnected/reconnecting/stopped
                    if repl.status != :ready
                        return
                    end

                    # Check if heartbeat is stale (>30 seconds old)
                    time_since_heartbeat = now() - repl.last_heartbeat
                    if time_since_heartbeat > Second(30)
                        @warn "REPL heartbeat timeout, marking as disconnected" id = repl_id last_heartbeat =
                            repl.last_heartbeat time_since = time_since_heartbeat status_before =
                            repl.status

                        REPL_REGISTRY[repl_id].status = :disconnected
                        REPL_REGISTRY[repl_id].disconnect_time = now()
                        REPL_REGISTRY[repl_id].missed_heartbeats += 1

                        # Log disconnection event
                        Dashboard.log_event(
                            repl_id,
                            Dashboard.ERROR,
                            Dict(
                                "message" => "Heartbeat timeout after $time_since_heartbeat",
                            ),
                        )
                    end
                end
            end
        catch e
            @error "Error in heartbeat monitor" exception = (e, catch_backtrace())
        end
    end

    @info "Heartbeat monitor stopped"
end

"""
    route_to_repl_streaming(request::Dict, original_req::HTTP.Request, http::HTTP.Stream) -> Nothing

Route a request to the appropriate backend REPL with streaming support.

Routing priority:
1. Mcp-Session-Id header (standard MCP session)
2. X-MCPRepl-Target header (explicit target specification)
3. Smart routing (prefer MCPRepl agent, or first available)
"""
function route_to_repl_streaming(
    request::Dict,
    original_req::HTTP.Request,
    http::HTTP.Stream,
)
    # Check for MCP session ID first (standard MCP mechanism)
    session_id_header = HTTP.header(original_req, "Mcp-Session-Id")
    target_id = nothing

    if !isempty(session_id_header)
        session_id = String(session_id_header)
        session = get_mcp_session(session_id)

        if session !== nothing
            # Update session activity
            update_activity!(session)
            target_id = session.target_repl_id
            @debug "Routing via session" session_id = session_id target_id = target_id
        else
            # Session not found - client needs to re-initialize
            HTTP.setstatus(http, 404)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32001,
                            "message" => "Session not found. Please send a new initialize request.",
                        ),
                    ),
                ),
            )
            return nothing
        end
    end

    # Fall back to X-MCPRepl-Target header if no session
    if target_id === nothing
        header_value = HTTP.header(original_req, "X-MCPRepl-Target")
        target_id = isempty(header_value) ? nothing : String(header_value)
    end

    # If still no target, this request requires a backend REPL but none is available
    if target_id === nothing
        repls = list_repls()
        if isempty(repls)
            HTTP.setstatus(http, 503)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32001,
                            "message" => "No Julia sessions available. Use proxy tools to list or start sessions: list_julia_sessions, start_julia_session.",
                        ),
                    ),
                ),
            )
            return nothing
        else
            # REPLs exist but session doesn't have a target
            HTTP.setstatus(http, 400)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            available_agents = join([r.id for r in repls], ", ")
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "error" => Dict(
                            "code" => -32001,
                            "message" => "No target REPL specified for this session. Available agents: $available_agents. Re-initialize with X-MCPRepl-Target header to specify a target.",
                        ),
                    ),
                ),
            )
            return nothing
        end
    end

    # Get the REPL connection
    repl = get_repl(target_id)

    if repl === nothing
        HTTP.setstatus(http, 404)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(
            http,
            JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" =>
                        Dict("code" => -32002, "message" => "REPL not found: $target_id"),
                ),
            ),
        )
        return nothing
    end

    # Handle REPL status
    if repl.status == :disconnected || repl.status == :reconnecting
        # Buffer the request and keep stream open with status updates
        lock(REPL_REGISTRY_LOCK) do
            if haskey(REPL_REGISTRY, target_id)
                # Add request to buffer
                push!(REPL_REGISTRY[target_id].pending_requests, (request, http))

                # Mark as reconnecting if not already
                if REPL_REGISTRY[target_id].status == :disconnected
                    REPL_REGISTRY[target_id].status = :reconnecting
                    @info "REPL disconnected, buffering requests and attempting reconnection" id =
                        target_id buffer_size =
                        length(REPL_REGISTRY[target_id].pending_requests)

                    # Start async reconnection task
                    @async try_reconnect(target_id)
                end
            end
        end

        # Start async task to send status updates while waiting for reconnection
        @async send_reconnection_updates(target_id, request, http)
        return nothing

    elseif repl.status == :stopped
        # REPL is permanently stopped, return error
        HTTP.setstatus(http, 503)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(
            http,
            JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32003,
                        "message" => "REPL permanently stopped: $target_id. Restart required.",
                    ),
                ),
            ),
        )
        return nothing

    elseif repl.status != :ready
        HTTP.setstatus(http, 503)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(
            http,
            JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", nothing),
                    "error" => Dict(
                        "code" => -32003,
                        "message" => "REPL not ready: $(repl.status)",
                    ),
                ),
            ),
        )
        return nothing
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
            Dashboard.log_event(
                target_id,
                Dashboard.TOOL_CALL,
                Dict("tool" => tool_name, "method" => method, "arguments" => tool_args),
            )
        elseif !isempty(method)
            # Log other methods as code execution
            Dashboard.log_event(
                target_id,
                Dashboard.CODE_EXECUTION,
                Dict("method" => method),
            )
        end

        start_time = time()
        @info "Sending request to backend" url = backend_url method = method body_length =
            length(body_str)

        # Make request to backend - use simple HTTP.request with response streaming disabled
        backend_response = HTTP.request(
            "POST",
            backend_url,
            ["Content-Type" => "application/json"],
            body_str;
            readtimeout=30,
            connect_timeout=5,
            status_exception=false,
        )

        duration_ms = (time() - start_time) * 1000
        response_body = String(backend_response.body)
        response_status = backend_response.status
        response_headers = Dict{String,String}()
        for (name, value) in backend_response.headers
            response_headers[name] = value
        end

        @info "Received response from backend" status = response_status body_length =
            length(response_body)

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
        Dashboard.log_event(
            target_id,
            Dashboard.OUTPUT,
            response_data;
            duration_ms=duration_ms,
        )

        # Update last heartbeat
        update_repl_status(target_id, :ready)

        # Forward response to client with proper headers
        @info "Returning response to client" status = response_status body_length =
            length(response_body)
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

        # Store the error and mark as disconnected
        error_summary = length(error_msg) > 500 ? error_msg[1:500] * "..." : error_msg

        # Mark as disconnected and buffer this request
        lock(REPL_REGISTRY_LOCK) do
            if haskey(REPL_REGISTRY, target_id)
                REPL_REGISTRY[target_id].last_error = error_summary
                REPL_REGISTRY[target_id].missed_heartbeats += 1

                # Only permanently stop after extended disconnect (2 minutes)
                if REPL_REGISTRY[target_id].status == :disconnected &&
                   REPL_REGISTRY[target_id].disconnect_time !== nothing &&
                   (now() - REPL_REGISTRY[target_id].disconnect_time) > Minute(2)
                    REPL_REGISTRY[target_id].status = :stopped
                    @warn "REPL permanently stopped after 2 minutes disconnected" id =
                        target_id

                    # Fail all pending requests
                    flush_pending_requests_with_error(target_id, "REPL permanently stopped")
                else
                    # First failure - mark as disconnected
                    if REPL_REGISTRY[target_id].status == :ready
                        REPL_REGISTRY[target_id].status = :disconnected
                        REPL_REGISTRY[target_id].disconnect_time = now()
                        @info "REPL disconnected, will buffer requests and retry" id =
                            target_id
                    end

                    # Buffer this request
                    push!(REPL_REGISTRY[target_id].pending_requests, (request, http))
                    @info "Request buffered" id = target_id buffer_size =
                        length(REPL_REGISTRY[target_id].pending_requests)

                    # Start reconnection attempts
                    if REPL_REGISTRY[target_id].status == :disconnected
                        REPL_REGISTRY[target_id].status = :reconnecting
                        @async try_reconnect(target_id)
                    end
                end
            end
        end

        # Log error event
        Dashboard.log_event(
            target_id,
            Dashboard.ERROR,
            Dict("message" => sprint(showerror, e), "method" => get(request, "method", "")),
        )

        # Don't send response - will be handled by reconnection logic
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
        @info "Incoming request" method = req.method target = req.target content_length =
            length(body)

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
        if (path == "/dashboard/" || startswith(path, "/dashboard/")) &&
           !startswith(path, "/dashboard/api/")
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
            end

            # Vite not running or failed - serve built static files
            asset_path = replace(path, r"^/dashboard/" => "")
            response = Dashboard.serve_static_file(asset_path)
            HTTP.setstatus(http, response.status)
            for (name, value) in response.headers
                HTTP.setheader(http, name => value)
            end
            HTTP.startwrite(http)
            write(http, response.body)
            return nothing
        end        # Dashboard API: Get proxy server info
        if path == "/dashboard/api/proxy-info"
            proxy_info = Dict(
                "pid" => getpid(),
                "port" => begin
                    local port = 3000
                    if SERVER[] !== nothing
                        try
                            port_match = match(r":(\d+)", string(SERVER[].listener))
                            if port_match !== nothing
                                port = parse(Int, port_match[1])
                            end
                        catch
                            port = 3000
                        end
                    end
                    port
                end,
                "version" => "v0.4.0",
            )
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(proxy_info))
            return nothing
        end

        # Dashboard API: Get all sessions
        if path == "/dashboard/api/sessions"
            start_time = time()
            sessions = lock(REPL_REGISTRY_LOCK) do
                result = Dict{String,Any}()
                for (id, conn) in REPL_REGISTRY
                    result[id] = Dict(
                        "id" => id,
                        "port" => conn.port,
                        "pid" => conn.pid,
                        "status" => string(conn.status),
                        "last_heartbeat" => Dates.format(
                            conn.last_heartbeat,
                            "yyyy-mm-dd HH:MM:SS",
                        ),
                    )
                end
                result
            end
            elapsed = (time() - start_time) * 1000
            if elapsed > 100
                @warn "Slow sessions API call" elapsed_ms = elapsed
            end
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(sessions))
            return nothing
        end

        # Dashboard API: Restart a specific session
        if startswith(path, "/dashboard/api/session/") &&
           endswith(path, "/restart") &&
           req.method == "POST"
            session_id =
                replace(path, r"^/dashboard/api/session/" => "", r"/restart$" => "")

            success = lock(REPL_REGISTRY_LOCK) do
                if haskey(REPL_REGISTRY, session_id)
                    conn = REPL_REGISTRY[session_id]

                    # Send restart request via exit tool
                    try
                        restart_req = Dict(
                            "jsonrpc" => "2.0",
                            "id" => rand(1:999999),
                            "method" => "tools/call",
                            "params" => Dict(
                                "name" => "exit",
                                "arguments" => Dict("restart" => true),
                            ),
                        )
                        write(conn.socket, JSON.json(restart_req) * "\n")
                        @info "Session restart requested" session_id
                        return true
                    catch e
                        @error "Failed to restart session" session_id error = e
                        return false
                    end
                else
                    @warn "Session not found for restart" session_id
                    return false
                end
            end

            HTTP.setstatus(http, success ? 200 : 404)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict("success" => success, "session_id" => session_id)))
            return nothing
        end

        # Dashboard API: Shutdown a specific session
        if startswith(path, "/dashboard/api/session/") &&
           endswith(path, "/shutdown") &&
           req.method == "POST"
            session_id =
                replace(path, r"^/dashboard/api/session/" => "", r"/shutdown$" => "")

            success = lock(REPL_REGISTRY_LOCK) do
                if haskey(REPL_REGISTRY, session_id)
                    conn = REPL_REGISTRY[session_id]

                    # If disconnected, just unregister it
                    if conn.status == :disconnected
                        delete!(REPL_REGISTRY, session_id)
                        @info "Unregistered disconnected session" session_id
                        return true
                    end

                    # Otherwise, try to send shutdown request
                    try
                        shutdown_req = Dict(
                            "jsonrpc" => "2.0",
                            "id" => rand(1:999999),
                            "method" => "shutdown",
                            "params" => Dict(),
                        )
                        write(conn.socket, JSON.json(shutdown_req) * "\n")

                        # Remove from registry
                        delete!(REPL_REGISTRY, session_id)
                        @info "Session shutdown requested" session_id
                        return true
                    catch e
                        # If write fails, just unregister anyway
                        delete!(REPL_REGISTRY, session_id)
                        @warn "Failed to send shutdown request, unregistered anyway" session_id error =
                            e
                        return true
                    end
                else
                    @warn "Session not found for shutdown" session_id
                    return false
                end
            end

            HTTP.setstatus(http, success ? 200 : 404)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(Dict("success" => success, "session_id" => session_id)))
            return nothing
        end

        # Dashboard API: Get tools (proxy + selected agent)
        if path == "/dashboard/api/tools"
            agent_id = nothing
            for (k, v) in req.headers
                if lowercase(k) == "x-agent-id"
                    agent_id = v
                    break
                end
            end

            result = Dict{String,Any}(
                "proxy_tools" => get_proxy_tool_schemas(),
                "agent_tools" => Dict{String,Any}(),
            )

            # If agent_id specified, fetch tools from that agent
            if agent_id !== nothing && haskey(REPL_REGISTRY, agent_id)
                conn = REPL_REGISTRY[agent_id]
                if conn.status == :ready
                    try
                        # Make tools/list request to agent
                        agent_req = Dict(
                            "jsonrpc" => "2.0",
                            "id" => 1,
                            "method" => "tools/list",
                            "params" => Dict(),
                        )

                        agent_resp = HTTP.post(
                            "http://127.0.0.1:$(conn.port)/",
                            ["Content-Type" => "application/json"],
                            JSON.json(agent_req);
                            readtimeout=5,
                        )

                        if agent_resp.status == 200
                            agent_data = JSON.parse(String(agent_resp.body))
                            if haskey(agent_data, "result") &&
                               haskey(agent_data["result"], "tools")
                                result["agent_tools"][agent_id] =
                                    agent_data["result"]["tools"]
                            end
                        end
                    catch e
                        @warn "Failed to fetch tools from agent" agent_id = agent_id exception =
                            e
                    end
                end
            end

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(result))
            return nothing
        end

        # Dashboard API: List directories for path autocomplete
        if path == "/dashboard/api/directories"
            # Get path prefix from query params
            path_prefix = ""

            if !isempty(req.target)
                uri = HTTP.URI(req.target)
                params = HTTP.queryparams(uri.query)
                path_prefix = get(params, "path", "")
            end

            result =
                Dict{String,Any}("directories" => String[], "is_julia_project" => false)

            try
                # Expand ~ to home directory
                expanded_path = expanduser(path_prefix)

                # Check if current path is a Julia project (has Project.toml)
                if isdir(expanded_path)
                    project_toml = joinpath(expanded_path, "Project.toml")
                    result["is_julia_project"] = isfile(project_toml)
                end

                # If path ends with /, list contents of that directory
                # Otherwise, list contents of parent directory and filter
                if isdir(expanded_path)
                    base_dir = expanded_path
                    filter_prefix = ""
                else
                    base_dir = dirname(expanded_path)
                    filter_prefix = basename(expanded_path)
                end

                if isdir(base_dir)
                    entries = readdir(base_dir, join=false)

                    # Filter directories only
                    for entry in entries
                        full_path = joinpath(base_dir, entry)
                        # Include directories and filter by prefix
                        if isdir(full_path) && startswith(entry, filter_prefix)
                            # Return path relative to what user typed
                            if endswith(expanded_path, "/") || isdir(expanded_path)
                                result["directories"] = push!(
                                    result["directories"],
                                    joinpath(path_prefix, entry),
                                )
                            else
                                result["directories"] = push!(
                                    result["directories"],
                                    joinpath(dirname(path_prefix), entry),
                                )
                            end
                        end
                    end

                    # Sort results
                    sort!(result["directories"])

                    # Limit to 20 results
                    if length(result["directories"]) > 20
                        result["directories"] = result["directories"][1:20]
                    end
                end
            catch e
                result["error"] = "Failed to list directories: $(sprint(showerror, e))"
            end

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(result))
            return nothing
        end

        # Dashboard API: Get logs for a session
        if path == "/dashboard/api/logs"
            # Get session_id from query params
            session_id = nothing
            lines = 500  # default number of lines

            if !isempty(req.target)
                uri = HTTP.URI(req.target)
                params = HTTP.queryparams(uri.query)
                session_id = get(params, "session_id", nothing)
                lines_str = get(params, "lines", "500")
                lines = tryparse(Int, lines_str)
                if lines === nothing
                    lines = 500
                end
            end

            result = Dict{String,Any}()

            if session_id !== nothing
                # Get log file for specific session
                log_dir = joinpath(dirname(@__DIR__), "logs")
                if isdir(log_dir)
                    # Find most recent log file for this session
                    log_files = filter(
                        f -> startswith(f, "session_$(session_id)_"),
                        readdir(log_dir),
                    )
                    if !isempty(log_files)
                        latest_log = joinpath(log_dir, sort(log_files)[end])
                        if isfile(latest_log)
                            try
                                content = read(latest_log, String)
                                # Get last N lines
                                all_lines = split(content, '\n')
                                selected_lines =
                                    all_lines[max(1, length(all_lines) - lines + 1):end]
                                result["content"] = join(selected_lines, '\n')
                                result["file"] = latest_log
                                result["total_lines"] = length(all_lines)
                            catch e
                                result["error"] = "Failed to read log file: $(sprint(showerror, e))"
                            end
                        else
                            result["error"] = "Log file not found"
                        end
                    else
                        result["error"] = "No log files found for session: $session_id"
                    end
                else
                    result["error"] = "Logs directory does not exist"
                end
            else
                # List all available log files
                log_dir = joinpath(dirname(@__DIR__), "logs")
                if isdir(log_dir)
                    files = readdir(log_dir)
                    result["files"] = map(files) do f
                        path = joinpath(log_dir, f)
                        Dict(
                            "name" => f,
                            "size" => filesize(path),
                            "modified" => string(Dates.unix2datetime(mtime(path))),
                        )
                    end
                else
                    result["files"] = []
                end
            end

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, JSON.json(result))
            return nothing
        end

        # Dashboard API: Restart proxy server
        if path == "/dashboard/api/restart" && req.method == "POST"
            @info "Restart endpoint called" pid = getpid()

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(Dict("status" => "ok", "message" => "Restarting proxy server")),
            )

            @info "Response sent, scheduling restart"

            # Schedule restart after response is sent
            @async begin
                try
                    sleep(0.5)
                    @info "Restarting proxy server via dashboard"

                    # Get port before closing
                    local port = 3000
                    if SERVER[] !== nothing
                        try
                            port_match = match(r":(\d+)", string(SERVER[].listener))
                            if port_match !== nothing
                                port = parse(Int, port_match[1])
                            end
                        catch
                            port = 3000
                        end

                        # Spawn new proxy with delay, then exit immediately
                        # Let the OS clean up the server on process exit
                        script_dir = dirname(@__FILE__)
                        proxy_script = joinpath(dirname(script_dir), "proxy.jl")

                        # Use shell to wait for port to be free, then start new proxy
                        restart_cmd = """
                        sleep 2
                        while lsof -i :$port >/dev/null 2>&1; do
                            sleep 0.5
                        done
                        julia $proxy_script start --background
                        """

                        @info "Spawning restart process (will wait for port to clear)..."
                        run(`sh -c $restart_cmd`, wait=false)

                        @info "Removing PID file..."
                        remove_pid_file(port)
                    end

                    # Flush logs before exit
                    @info "Exiting current process..."
                    flush(stderr)
                    flush(stdout)
                    sleep(0.1)

                    # Exit current process
                    exit(0)
                catch e
                    @error "Error during restart" exception = (e, catch_backtrace())
                    exit(1)
                end
            end
            return nothing
        end

        # Dashboard API: Shutdown proxy server
        if path == "/dashboard/api/shutdown" && req.method == "POST"
            @info "Shutdown endpoint called" pid = getpid()

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict("status" => "ok", "message" => "Shutting down proxy server"),
                ),
            )

            @info "Response sent, scheduling shutdown"

            # Schedule shutdown after response is sent
            @async begin
                @info "Shutdown task started"
                sleep(0.5)  # Give time for response to be sent
                @info "Proxy server shutdown requested via dashboard" pid = getpid()

                # Get port from SERVER before closing
                local port = 3000
                if SERVER[] !== nothing
                    try
                        port_match = match(r":(\d+)", string(SERVER[].listener))
                        if port_match !== nothing
                            port = parse(Int, port_match[1])
                        end
                    catch
                        port = 3000
                    end

                    @info "Shutting down proxy server" port = port

                    # Proper shutdown sequence
                    stop_vite_dev_server()
                    close(SERVER[])
                    SERVER[] = nothing
                    remove_pid_file(port)

                    @info "Server closed, exiting process"
                end

                # Force exit the Julia process
                @info "Calling exit(0)"
                sleep(0.1)
                exit(0)
            end
            return nothing
        end        # Dashboard API: Get events
        if path == "/dashboard/api/events"
            query_params = HTTP.queryparams(uri)
            id = get(query_params, "id", nothing)
            limit = parse(Int, get(query_params, "limit", "100"))

            events = Dashboard.get_events(id=id, limit=limit)
            events_json = [
                Dict(
                    "id" => e.id,
                    "type" => string(e.event_type),
                    "timestamp" => Dates.format(e.timestamp, "yyyy-mm-dd HH:MM:SS.sss"),
                    "data" => e.data,
                    "duration_ms" => e.duration_ms,
                ) for e in events
            ]

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
                            "timestamp" => Dates.format(
                                event.timestamp,
                                "yyyy-mm-dd HH:MM:SS.sss",
                            ),
                            "data" => event.data,
                            "duration_ms" => event.duration_ms,
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
                    @debug "SSE stream error" exception = e
                end
            end

            return nothing
        end

        # Dashboard API: Generate test events
        if path == "/dashboard/api/test-events"
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)

            test_agent = "test-agent"

            # Generate sample events of all types
            Dashboard.log_event(test_agent, Dashboard.HEARTBEAT, Dict("status" => "ok"))

            Dashboard.log_event(
                test_agent,
                Dashboard.TOOL_CALL,
                Dict(
                    "tool" => "ex",
                    "arguments" => Dict("e" => "println(\"Hello, World!\")"),
                ),
                duration_ms=12.5,
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.CODE_EXECUTION,
                Dict("expression" => "2 + 2", "result" => "4"),
                duration_ms=0.8,
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.OUTPUT,
                Dict("text" => "Hello, World!"),
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.ERROR,
                Dict("message" => "UndefVarError: x not defined", "stacktrace" => "..."),
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.AGENT_START,
                Dict("port" => 3000, "pid" => getpid()),
            )

            Dashboard.log_event(
                test_agent,
                Dashboard.AGENT_STOP,
                Dict("reason" => "shutdown"),
            )

            write(
                http,
                JSON.json(Dict("status" => "ok", "message" => "Test events generated")),
            )
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
                HTTP.setheader(
                    http,
                    "Access-Control-Allow-Headers" => "Content-Type, Authorization",
                )
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
                write(
                    http,
                    JSON.json(
                        Dict(
                            "status" => "ok",
                            "type" => "mcprepl-proxy",
                            "version" => "0.1.0",
                            "pid" => getpid(),
                            "uptime" => time(),
                            "protocol" => "MCP 2024-11-05",
                        ),
                    ),
                )
                return nothing
            end
            # Empty POST body - invalid request
            HTTP.setstatus(http, 400)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "error" => Dict(
                            "code" => -32700,
                            "message" => "Parse error: empty request body",
                        ),
                        "id" => nothing,
                    ),
                ),
            )
            return nothing
        end

        # Parse JSON-RPC request
        request = JSON.parse(body)

        # Log all incoming requests with full details
        method = get(request, "method", "")
        request_id = get(request, "id", nothing)
        params = get(request, "params", nothing)
        @info "📨 MCP Request" method = method id = request_id has_params =
            !isnothing(params)

        if method == "proxy/status"
            repls = list_repls()
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict(
                            "status" => "running",
                            "pid" => getpid(),
                            "port" => SERVER_PORT[],
                            "connected_repls" => length(repls),
                            "repls" => [
                                Dict(
                                    "id" => r.id,
                                    "port" => r.port,
                                    "status" => string(r.status),
                                    "pid" => r.pid,
                                    "last_error" => r.last_error,
                                ) for r in repls
                            ],
                            "uptime" => time(),
                        ),
                    ),
                ),
            )
            return nothing
        elseif method == "proxy/register"
            # Register a new REPL
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)
            port = get(params, "port", nothing)
            pid = get(params, "pid", nothing)
            metadata_raw = get(params, "metadata", Dict())

            # Convert JSON.Object to Dict if needed
            metadata =
                metadata_raw isa Dict ? metadata_raw :
                Dict(String(k) => v for (k, v) in pairs(metadata_raw))

            if id === nothing || port === nothing
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "error" => Dict(
                                "code" => -32602,
                                "message" => "Invalid params: 'id' and 'port' are required",
                            ),
                        ),
                    ),
                )
                return nothing
            end

            register_repl(id, port; pid=pid, metadata=metadata)

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict("status" => "registered", "id" => id),
                    ),
                ),
            )
            return nothing
        elseif method == "proxy/unregister"
            # Unregister a REPL
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "error" => Dict(
                                "code" => -32602,
                                "message" => "Invalid params: 'id' is required",
                            ),
                        ),
                    ),
                )
                return nothing
            end

            unregister_repl(id)

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict("status" => "unregistered", "id" => id),
                    ),
                ),
            )
            return nothing
        elseif method == "proxy/heartbeat"
            # REPL sends heartbeat to indicate it's alive
            params = get(request, "params", Dict())
            id = get(params, "id", nothing)

            if id === nothing
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "error" => Dict(
                                "code" => -32602,
                                "message" => "Invalid params: 'id' is required",
                            ),
                        ),
                    ),
                )
                return nothing
            end

            # Update heartbeat and recover from disconnected/stopped state
            lock(REPL_REGISTRY_LOCK) do
                if haskey(REPL_REGISTRY, id)
                    REPL_REGISTRY[id].last_heartbeat = now()
                    REPL_REGISTRY[id].missed_heartbeats = 0  # Reset counter on successful heartbeat
                    # Automatically recover from disconnected or stopped state on heartbeat
                    if REPL_REGISTRY[id].status in (:stopped, :disconnected, :reconnecting)
                        old_status = REPL_REGISTRY[id].status
                        REPL_REGISTRY[id].status = :ready
                        REPL_REGISTRY[id].last_error = nothing
                        REPL_REGISTRY[id].disconnect_time = nothing
                        @info "REPL recovered via heartbeat" id = id old_status = old_status
                    end

                    # Log heartbeat event (don't spam - could be rate limited in Dashboard module)
                    Dashboard.log_event(id, Dashboard.HEARTBEAT, Dict("status" => "ok"))
                end
            end

            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict("status" => "ok"),
                    ),
                ),
            )
            return nothing
        elseif method == "initialize"
            # Handle MCP initialize request according to spec
            # Check for X-MCPRepl-Target header to determine routing
            header_value = HTTP.header(req, "X-MCPRepl-Target")
            target_repl_id = isempty(header_value) ? nothing : String(header_value)

            # Get initialization parameters
            params = get(request, "params", Dict())
            client_info = get(params, "clientInfo", Dict())
            client_name = get(client_info, "name", "unknown")

            @info "MCP initialize request" target_repl_id = target_repl_id client_name =
                client_name

            # X-MCPRepl-Target header is optional
            # If specified, session will route to that REPL
            # If not specified, session can use proxy tools to list/select/start REPLs
            # Session is always created as per MCP spec

            # Create MCP session with optional target REPL mapping
            session = create_mcp_session(target_repl_id)

            # Initialize the session using the Session module for proper capability negotiation
            # Convert JSON.Object to Dict if necessary
            params_dict =
                params isa Dict ? params : Dict(String(k) => v for (k, v) in pairs(params))
            result = initialize_session!(session, params_dict)

            # Register client connection for notifications
            notification_channel = register_client_connection(session.id)

            # Respond with session ID header as per MCP spec
            # The Mcp-Session-Id header tells the client to include this ID on all subsequent requests
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.setheader(http, "Mcp-Session-Id" => session.id)
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => result,
                    ),
                ),
            )
            return nothing
        elseif method == "logging/setLevel"
            # Handle MCP logging/setLevel request
            params = get(request, "params", Dict())
            level = get(params, "level", nothing)

            # Validate log level according to RFC 5424
            valid_levels = [
                "debug",
                "info",
                "notice",
                "warning",
                "error",
                "critical",
                "alert",
                "emergency",
            ]

            if level === nothing || !(level in valid_levels)
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "error" => Dict(
                                "code" => -32602,
                                "message" => "Invalid params: level must be one of $(join(valid_levels, ", "))",
                            ),
                        ),
                    ),
                )
                return nothing
            end

            # Map MCP log levels to Julia Logging levels
            level_map = Dict(
                "debug" => Logging.Debug,
                "info" => Logging.Info,
                "notice" => Logging.Info,
                "warning" => Logging.Warn,
                "error" => Logging.Error,
                "critical" => Logging.Error,
                "alert" => Logging.Error,
                "emergency" => Logging.Error,
            )

            julia_level = level_map[level]

            # Set the global log level
            try
                global_logger(ConsoleLogger(stderr, julia_level))
                @info "Log level set" level = level julia_level = julia_level
            catch e
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "error" => Dict(
                                "code" => -32603,
                                "message" => "Internal error: $(string(e))",
                            ),
                        ),
                    ),
                )
                return nothing
            end

            # Success response (empty result as per spec)
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict(),
                    ),
                ),
            )
            return nothing
        elseif method == "tools/list"
            # Get proxy tools (always available)
            proxy_tools = get_proxy_tool_schemas()

            # Check if this request is from a session with a specific target REPL
            session_id_header = HTTP.header(req, "Mcp-Session-Id")
            target_repl_id = nothing

            if !isempty(session_id_header)
                session_id = String(session_id_header)
                session = get_mcp_session(session_id)
                if session !== nothing
                    update_activity!(session)
                    target_repl_id = session.target_repl_id
                    @debug "tools/list for session" session_id = session_id target_repl_id =
                        target_repl_id
                end
            end

            # If no session or no target REPL, return only proxy tools
            if target_repl_id === nothing
                repls = list_repls()
                @info "tools/list - no target REPL" num_repls = length(repls) returning = "proxy tools only"

                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "result" => Dict("tools" => proxy_tools),
                        ),
                    ),
                )
                return nothing
            end

            # Fetch tools from the target REPL and combine with proxy tools
            repl = get_repl(target_repl_id)
            all_tools = copy(proxy_tools)

            if repl !== nothing && repl.status == :ready
                try
                    request_dict =
                        request isa Dict ? request :
                        Dict(String(k) => v for (k, v) in pairs(request))

                    backend_url = "http://127.0.0.1:$(repl.port)/"
                    body_str = JSON.json(request_dict)
                    backend_response = HTTP.request(
                        "POST",
                        backend_url,
                        ["Content-Type" => "application/json"],
                        body_str;
                        readtimeout=5,
                        connect_timeout=2,
                        status_exception=false,
                    )

                    if backend_response.status == 200
                        backend_data = JSON.parse(String(backend_response.body))
                        if haskey(backend_data, "result") &&
                           haskey(backend_data["result"], "tools")
                            backend_tools = backend_data["result"]["tools"]
                            append!(all_tools, backend_tools)
                            @info "tools/list - combined tools" target_repl_id =
                                target_repl_id proxy_tools = length(proxy_tools) backend_tools =
                                length(backend_tools) total = length(all_tools)
                        end
                    end
                catch e
                    @warn "Failed to fetch tools from target REPL, returning proxy tools only" repl_id =
                        target_repl_id exception = e
                end
            else
                @info "Target REPL not ready, returning proxy tools only" target_repl_id =
                    target_repl_id status = repl !== nothing ? repl.status : :not_found
            end

            # Return combined tools from proxy + target REPL
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(
                http,
                JSON.json(
                    Dict(
                        "jsonrpc" => "2.0",
                        "id" => get(request, "id", nothing),
                        "result" => Dict("tools" => all_tools),
                    ),
                ),
            )
            return nothing
        elseif method == "tools/call"
            # Handle proxy-level tools (always available)
            params = get(request, "params", Dict())
            tool_name = get(params, "name", "")
            repls = list_repls()

            # Check if this is a proxy tool
            if haskey(PROXY_TOOLS, tool_name)
                tool = PROXY_TOOLS[tool_name]
                args = get(params, "arguments", Dict())

                # Call tool handler with appropriate context
                result_text = if tool_name == "help"
                    tool.handler(args)
                elseif tool_name in ["proxy_status", "list_julia_sessions"]
                    tool.handler(args, repls)
                elseif tool_name == "dashboard_url"
                    tool.handler(args)
                elseif tool_name == "start_julia_session"
                    # Special handling - continue to existing implementation below
                    nothing
                else
                    tool.handler(args)
                end

                # If start_julia_session, continue to existing code
                if tool_name == "start_julia_session" && result_text === nothing
                    # Fall through to existing implementation
                elseif result_text !== nothing
                    # Return result for other tools
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "result" => Dict(
                                    "content" =>
                                        [Dict("type" => "text", "text" => result_text)],
                                ),
                            ),
                        ),
                    )
                    return nothing
                end
            end

            # Handle kill_stale_sessions with special logic
            if tool_name == "kill_stale_sessions"
                args = get(params, "arguments", Dict())
                dry_run = get(args, "dry_run", true)
                force = get(args, "force", false)
                proxy_port_filter = get(args, "proxy_port", nothing)

                result_text = ""
                try
                    if Sys.iswindows()
                        result_text = "❌ kill_stale_sessions is not yet supported on Windows"
                    else
                        # Fast approach: only check disconnected sessions from registry
                        # Avoid any process scanning which is slow
                        stale_processes = []

                        lock(REPL_REGISTRY_LOCK) do
                            for (session_name, conn) in REPL_REGISTRY
                                pid = conn.pid

                                # Check proxy port filter if specified
                                if proxy_port_filter !== nothing &&
                                   string(conn.port) != string(proxy_port_filter)
                                    continue
                                end

                                # Only flag disconnected sessions as stale
                                if conn.status == :disconnected
                                    is_stale = true
                                    if force || is_stale
                                        push!(
                                            stale_processes,
                                            (pid, session_name, is_stale),
                                        )
                                    end
                                elseif force
                                    # Force mode - include all active sessions too
                                    is_stale = false
                                    push!(stale_processes, (pid, session_name, is_stale))
                                end
                            end
                        end

                        if isempty(stale_processes)
                            result_text = "✅ No stale MCPRepl sessions found"
                        else
                            result_text = "Found $(length(stale_processes)) MCPRepl session(s):\n\n"
                            for (pid, session_name, is_stale) in stale_processes
                                status =
                                    is_stale ? "❌ STALE (not registered)" :
                                    "✅ Active (registered)"
                                result_text *= "  PID $pid: $session_name - $status\n"
                            end

                            if dry_run
                                result_text *= "\n🔍 DRY RUN MODE - No processes killed\n"
                                result_text *= "Set dry_run=false to actually kill these processes"
                            else
                                result_text *= "\n💀 Killing processes...\n\n"
                                for (pid, session_name, is_stale) in stale_processes
                                    try
                                        run(`kill -9 $pid`)
                                        result_text *= "  ✅ Killed PID $pid ($session_name)\n"
                                        # Remove from registry if it was there
                                        lock(REPL_REGISTRY_LOCK) do
                                            delete!(REPL_REGISTRY, session_name)
                                        end
                                    catch e
                                        result_text *= "  ❌ Failed to kill PID $pid: $e\n"
                                    end
                                end
                            end
                        end
                    end
                catch e
                    result_text = "❌ Error scanning for stale sessions: $e"
                end

                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "result" => Dict(
                                "content" =>
                                    [Dict("type" => "text", "text" => result_text)],
                            ),
                        ),
                    ),
                )
                return nothing
            end

            # Handle start_julia_session with special logic
            if tool_name == "start_julia_session"
                # Parse arguments
                args = get(params, "arguments", Dict())
                project_path = get(args, "project_path", "")
                session_name = get(args, "session_name", basename(project_path))

                if isempty(project_path)
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "error" => Dict(
                                    "code" => -32602,
                                    "message" => "project_path is required",
                                ),
                            ),
                        ),
                    )
                    return nothing
                end

                # Check if Julia session already exists
                existing = findfirst(r -> r.id == session_name, repls)
                if existing !== nothing
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "result" => Dict(
                                    "content" => [
                                        Dict(
                                            "type" => "text",
                                            "text" => "Julia session '$session_name' is already running on port $(repls[existing].port)",
                                        ),
                                    ],
                                ),
                            ),
                        ),
                    )
                    return nothing
                end

                # Spawn new Julia session process
                try
                    @info "Starting Julia session" project_path = project_path session_id =
                        session_name

                    # Create log file for session output
                    log_dir = joinpath(dirname(@__DIR__), "logs")
                    mkpath(log_dir)
                    log_file = joinpath(
                        log_dir,
                        "session_$(session_name)_$(round(Int, time())).log",
                    )

                    # Build Julia command - inherit security config from the project itself
                    # Pass workspace_dir=project_path so it checks for .mcprepl/security.json in the project
                    # If project has .mcprepl/agents.json with this agent name, it uses that
                    # Otherwise falls back to .mcprepl/security.json or lax mode with warning
                    # Use wait() to keep the process alive until the server is stopped

                    julia_cmd = `julia --project=$project_path -e "using MCPRepl; MCPRepl.start!(agent_name=$(repr(session_name)), workspace_dir=$(repr(project_path))); wait()"`

                    # Add environment variable tag for easy identification
                    env = copy(ENV)
                    env["MCPREPL_SESSION"] = session_name
                    env["MCPREPL_PROXY_PORT"] =
                        string(get(ENV, "MCPREPL_PROXY_PORT", "3000"))

                    # Run in background, capture output to log file
                    proc = run(
                        pipeline(
                            setenv(julia_cmd, env),
                            stdout=log_file,
                            stderr=log_file,
                        ),
                        wait=false,
                    )

                    # Wait for Julia session to register (max 30 seconds to allow for precompilation)
                    # When agent_name is provided, MCPRepl registers using that name directly
                    registered = false
                    expected_id = session_name
                    for i = 1:300  # 30 seconds with 0.1s sleep
                        sleep(0.1)
                        current_repls = list_repls()
                        # Check for the expected registration ID
                        idx = findfirst(r -> r.id == expected_id, current_repls)
                        if idx !== nothing
                            registered = true
                            new_repl = current_repls[idx]
                            HTTP.setstatus(http, 200)
                            HTTP.setheader(http, "Content-Type" => "application/json")
                            HTTP.startwrite(http)
                            write(
                                http,
                                JSON.json(
                                    Dict(
                                        "jsonrpc" => "2.0",
                                        "id" => get(request, "id", nothing),
                                        "result" => Dict(
                                            "content" => [
                                                Dict(
                                                    "type" => "text",
                                                    "text" => "✅ Successfully started Julia session '$(new_repl.id)' on port $(new_repl.port)\n\nProject: $project_path\nPID: $(new_repl.pid)\nStatus: $(new_repl.status)\nLog: $log_file",
                                                ),
                                            ],
                                        ),
                                    ),
                                ),
                            )
                            return nothing
                        end
                    end

                    # Timeout - read log file for diagnostics
                    log_contents = ""
                    try
                        if isfile(log_file)
                            log_contents = read(log_file, String)
                            # Get last 500 characters
                            if length(log_contents) > 500
                                log_contents = "..." * log_contents[end-500:end]
                            end
                        end
                    catch
                        log_contents = "(unable to read log file)"
                    end

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "error" => Dict(
                                    "code" => -32603,
                                    "message" => "Julia session process started but did not register within 30 seconds.\n\nLog file: $log_file\n\nRecent output:\n$log_contents",
                                ),
                            ),
                        ),
                    )
                    return nothing
                catch e
                    @error "Failed to start Julia session" exception =
                        (e, catch_backtrace())
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "error" => Dict(
                                    "code" => -32603,
                                    "message" => "Failed to start REPL backend: $(sprint(showerror, e))",
                                ),
                            ),
                        ),
                    )
                    return nothing
                end
            else
                # Tool requires backend REPL - check if any are available
                if isempty(repls)
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "jsonrpc" => "2.0",
                                "id" => get(request, "id", nothing),
                                "result" => Dict(
                                    "content" => [
                                        Dict(
                                            "type" => "text",
                                            "text" => "⚠️ Tool '$tool_name' requires a Julia session.\n\nNo Julia sessions are currently connected to the proxy.\n\nTo enable Julia tools:\n1. Start a Julia session\n2. Run: using MCPRepl; MCPRepl.start!()\n3. The session will automatically register with this proxy\n\nAvailable proxy tools: help, proxy_status, list_julia_sessions, dashboard_url, start_julia_session",
                                        ),
                                    ],
                                ),
                            ),
                        ),
                    )
                    return nothing
                else
                    # Route to backend
                    request_dict =
                        request isa Dict ? request :
                        Dict(String(k) => v for (k, v) in pairs(request))
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
                write(
                    http,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "id" => get(request, "id", nothing),
                            "result" => nothing,  # Many MCP methods (like notifications) expect null result
                        ),
                    ),
                )
                return nothing
            else
                # Route to backend REPL
                request_dict =
                    request isa Dict ? request :
                    Dict(String(k) => v for (k, v) in pairs(request))
                route_to_repl_streaming(request_dict, req, http)
                return nothing
            end
        end

    catch e
        @error "Error handling request" exception = (e, catch_backtrace())
        HTTP.setstatus(http, 500)
        HTTP.setheader(http, "Content-Type" => "application/json")
        HTTP.startwrite(http)
        write(
            http,
            JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "error" => Dict(
                        "code" => -32603,
                        "message" => "Internal error: $(sprint(showerror, e))",
                    ),
                    "id" => nothing,
                ),
            ),
        )
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
    server =
        HTTP.serve!(handle_request, ip"127.0.0.1", port; verbose=false, stream=true)
    SERVER[] = server

    # Start background heartbeat monitor AFTER setting SERVER[]
    @async monitor_heartbeats()

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
        # Unix: use nohup and discard stdout/stderr (all logs go to proxy-$port.log via FileLogger)
        run(
            pipeline(`nohup julia $script_file`, stdout=devnull, stderr=devnull),
            wait=false,
        )
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
            status_callback(
                "Starting MCPRepl (waiting for proxy server... \033[38;5;203m$(elapsed_sec)s\033[0m)",
            )
        end

        if is_server_running(port)
            # Success
            if status_callback !== nothing
                status_callback("Starting MCPRepl (proxy server ready)")
            end
            pid = get_server_pid(port)
            @debug "Background proxy server started" port = port pid = pid elapsed_time =
                elapsed
            return nothing
        end

        sleep(check_interval)
        elapsed += check_interval
    end

    # Server didn't start in time
    @error "Failed to start background proxy server" timeout = max_wait
    @info "Check log file for details" log_file =
        joinpath(dirname(get_pid_file_path(port)), "proxy-$port.log")

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
