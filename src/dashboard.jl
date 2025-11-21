"""
Multi-Agent Dashboard for MCPRepl Proxy

Provides real-time visualization of agent activity across multiple Julia REPL sessions.
"""
module Dashboard

using HTTP
using JSON
using Dates
using Sockets
using OteraEngine
using Downloads
using Tar
using Scratch

# Event types for agent activity tracking
@enum EventType begin
    AGENT_START
    AGENT_STOP
    TOOL_CALL
    CODE_EXECUTION
    OUTPUT
    ERROR
    HEARTBEAT
end

# Structure for agent events
struct AgentEvent
    id::String              # REPL/Agent ID
    event_type::EventType
    timestamp::DateTime
    data::Dict{String,Any}
    duration_ms::Union{Float64,Nothing}
end

# Global event log (ring buffer to prevent memory growth)
const MAX_EVENTS = 10000
const EVENT_LOG = Vector{AgentEvent}()
const EVENT_LOG_LOCK = ReentrantLock()

# Active WebSocket connections for live updates
const WS_CLIENTS = Set{HTTP.WebSockets.WebSocket}()
const WS_CLIENTS_LOCK = ReentrantLock()

"""
    log_event(id::String, event_type::EventType, data::Dict; duration_ms=nothing)

Log an agent event and broadcast to connected dashboard clients.
"""
function log_event(id::String, event_type::EventType, data::Dict; duration_ms = nothing)
    event = AgentEvent(id, event_type, now(), data, duration_ms)

    lock(EVENT_LOG_LOCK) do
        push!(EVENT_LOG, event)
        # Keep only last MAX_EVENTS
        if length(EVENT_LOG) > MAX_EVENTS
            deleteat!(EVENT_LOG, 1:length(EVENT_LOG)-MAX_EVENTS)
        end
    end

    # Broadcast to WebSocket clients
    broadcast_event(event)
end

"""
    broadcast_event(event::AgentEvent)

Send event to all connected WebSocket clients.
"""
function broadcast_event(event::AgentEvent)
    event_json = JSON.json(
        Dict(
            "id" => event.id,
            "type" => string(event.event_type),
            "timestamp" => Dates.format(event.timestamp, "yyyy-mm-dd HH:MM:SS.sss"),
            "data" => event.data,
            "duration_ms" => event.duration_ms,
        ),
    )

    lock(WS_CLIENTS_LOCK) do
        for client in WS_CLIENTS
            try
                HTTP.WebSockets.send(client, event_json)
            catch e
                @debug "Failed to send to WebSocket client" exception = e
            end
        end
    end
end

"""
    get_events(; id=nothing, limit=100)

Retrieve recent events, optionally filtered by agent ID.
"""
function get_events(; id = nothing, limit = 100)
    lock(EVENT_LOG_LOCK) do
        events = if id === nothing
            EVENT_LOG
        else
            filter(e -> e.id == id, EVENT_LOG)
        end

        # Return most recent events
        start_idx = max(1, length(events) - limit + 1)
        return events[start_idx:end]
    end
end

"""
    dashboard_html()

Generate the main dashboard HTML page.
Serves React app if built, otherwise falls back to template.
"""
function dashboard_html()
    # Try to serve React build first
    react_dist = abspath(joinpath(@__DIR__, "..", "dashboard-ui", "dist", "index.html"))
    if isfile(react_dist)
        return read(react_dist, String)
    end

    # Fallback to template
    template_path = abspath(joinpath(@__DIR__, "..", "templates", "dashboard.html.tmpl"))
    if !isfile(template_path)
        error("Dashboard template not found: $template_path")
    end
    tmp = Template(template_path, config = Dict("autoescape" => false))
    return tmp(init = Dict())
end

"""
    download_dashboard_if_needed()

Download and extract the dashboard from GitHub releases if not already cached.
Returns the path to the extracted dashboard directory.
"""
function download_dashboard_if_needed()
    cache_dir = @get_scratch!("dashboard-cache")
    dashboard_dir = joinpath(cache_dir, "dist")

    # Check if already downloaded
    if isdir(dashboard_dir) && isfile(joinpath(dashboard_dir, "index.html"))
        return dashboard_dir
    end

    # Download from GitHub release
    url = "https://github.com/kahliburke/MCPRepl.jl/releases/download/dashboard-latest/dashboard-dist.tar.gz"
    tarball = joinpath(cache_dir, "dashboard-dist.tar.gz")

    @info "Downloading dashboard from GitHub..." url
    Downloads.download(url, tarball)

    # Extract
    @info "Extracting dashboard..."
    Tar.extract(tarball, cache_dir)

    # Clean up tarball
    rm(tarball; force = true)

    return dashboard_dir
end

"""
    serve_static_file(filepath::String)

Serve a static file from the React build directory with proper MIME type.
Uses the dashboard artifact in production, falls back to local dist/ in development.
"""
function serve_static_file(filepath::String)
    # Default to index.html if path is empty
    if isempty(filepath)
        filepath = "index.html"
    end

    # Try local dist first (development), then download from GitHub (production)
    local_dist = abspath(joinpath(@__DIR__, "..", "dashboard-ui", "dist"))

    react_dist = if isdir(local_dist) && isfile(joinpath(local_dist, "index.html"))
        # Development mode - use local build
        local_dist
    else
        # Production mode - download from GitHub release
        try
            download_dashboard_if_needed()
        catch e
            @warn "Failed to download dashboard, using local dist/" exception = e
            local_dist
        end
    end

    fullpath = joinpath(react_dist, filepath)

    if !isfile(fullpath) || !startswith(abspath(fullpath), react_dist)
        return HTTP.Response(404, "Not Found")
    end

    # Determine MIME type
    mime_types = Dict(
        ".html" => "text/html",
        ".js" => "application/javascript",
        ".mjs" => "application/javascript",
        ".css" => "text/css",
        ".json" => "application/json",
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".svg" => "image/svg+xml",
        ".ico" => "image/x-icon",
    )

    ext = lowercase(splitext(fullpath)[2])
    mime_type = get(mime_types, ext, "application/octet-stream")

    content = read(fullpath)
    return HTTP.Response(200, ["Content-Type" => mime_type], body = content)
end

end # module Dashboard
