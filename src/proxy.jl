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

# Global state
const SERVER = Ref{Union{HTTP.Server,Nothing}}(nothing)
const SERVER_PORT = Ref{Int}(3000)
const SERVER_PID_FILE = Ref{String}("")

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

"""
    handle_request(req::HTTP.Request) -> HTTP.Response

Handle incoming MCP requests. Currently just a health check endpoint.
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
        if get(request, "method", "") == "proxy/status"
            return HTTP.Response(200, JSON.json(Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", nothing),
                "result" => Dict(
                    "status" => "running",
                    "pid" => getpid(),
                    "port" => SERVER_PORT[],
                    "connected_repls" => 0,  # TODO: track connections
                    "uptime" => time()
                )
            )))
        end

        # TODO: Route to backend REPL
        return HTTP.Response(501, JSON.json(Dict(
            "jsonrpc" => "2.0",
            "id" => get(request, "id", nothing),
            "error" => Dict(
                "code" => -32601,
                "message" => "Method not implemented yet - routing to backend REPL coming soon"
            )
        )))

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
