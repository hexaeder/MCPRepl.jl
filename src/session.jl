# ============================================================================
# Session Management Module
# ============================================================================
# 
# Implements MCP session lifecycle management according to the specification:
# - Session initialization with protocol version negotiation
# - Capability negotiation
# - Session state management (uninitialized, initializing, initialized, closed)
# - Proper cleanup on session end

module Session

using JSON
using Dates
import UUIDs: uuid4

export MCPSession, SessionState, initialize_session!, close_session!, get_session_info

# Session states
@enum SessionState begin
    UNINITIALIZED  # Session created but not initialized
    INITIALIZING   # Initialize request received, processing
    INITIALIZED    # Successfully initialized and ready
    CLOSED         # Session has been closed
end

"""
    MCPSession

Represents an MCP protocol session with a client.

# Fields
- `id::String`: Unique session identifier (UUID)
- `state::SessionState`: Current session state
- `protocol_version::String`: Negotiated protocol version
- `client_info::Dict{String,Any}`: Client information from initialize
- `server_capabilities::Dict{String,Any}`: Server capabilities advertised to client
- `client_capabilities::Dict{String,Any}`: Client capabilities received during init
- `created_at::DateTime`: Session creation timestamp
- `initialized_at::Union{DateTime,Nothing}`: Session initialization timestamp
- `closed_at::Union{DateTime,Nothing}`: Session close timestamp
"""
mutable struct MCPSession
    id::String
    state::SessionState
    protocol_version::String
    client_info::Dict{String,Any}
    server_capabilities::Dict{String,Any}
    client_capabilities::Dict{String,Any}
    created_at::DateTime
    initialized_at::Union{DateTime,Nothing}
    closed_at::Union{DateTime,Nothing}
end

"""
    MCPSession() -> MCPSession

Create a new uninitialized MCP session.
"""
function MCPSession()
    return MCPSession(
        string(uuid4()),                    # id
        UNINITIALIZED,                      # state
        "",                                 # protocol_version
        Dict{String,Any}(),                 # client_info
        get_server_capabilities(),          # server_capabilities
        Dict{String,Any}(),                 # client_capabilities
        now(),                              # created_at
        nothing,                            # initialized_at
        nothing,                            # closed_at
    )
end

"""
    get_server_capabilities() -> Dict{String,Any}

Return the server's capabilities to advertise to clients.
"""
function get_server_capabilities()
    return Dict{String,Any}(
        "tools" => Dict{String,Any}(),  # We support tools (no specific features to advertise)
        "prompts" => Dict{String,Any}(),  # We support prompts
        "resources" => Dict{String,Any}(),  # We support resources
        "logging" => Dict{String,Any}(),  # We support logging
        "experimental" => Dict{String,Any}(
            "vscode_integration" => true,  # Custom VS Code integration
            "supervisor_mode" => true,     # Multi-agent supervision
            "proxy_routing" => true,       # Proxy-based routing
        ),
    )
end

"""
    initialize_session!(session::MCPSession, params::Dict) -> Dict{String,Any}

Initialize a session with protocol version and capability negotiation.

# Arguments
- `session::MCPSession`: The session to initialize
- `params::Dict`: Initialize request parameters containing:
  - `protocolVersion`: Required protocol version
  - `capabilities`: Client capabilities
  - `clientInfo`: Client information (name, version)

# Returns
Dictionary containing initialization response with:
- `protocolVersion`: Server's protocol version
- `capabilities`: Server capabilities
- `serverInfo`: Server information

# Throws
- `ErrorException`: If session is not in UNINITIALIZED state
- `ErrorException`: If protocol version is not supported
"""
function initialize_session!(session::MCPSession, params::Dict)
    # Validate session state
    if session.state != UNINITIALIZED
        error("Session already initialized or closed")
    end

    session.state = INITIALIZING

    # Extract and validate protocol version
    protocol_version = get(params, "protocolVersion", nothing)
    if protocol_version === nothing
        session.state = UNINITIALIZED
        error("Missing required parameter: protocolVersion")
    end

    # Validate protocol version (we support 2024-11-05)
    supported_version = "2024-11-05"
    if protocol_version != supported_version
        session.state = UNINITIALIZED
        error(
            "Unsupported protocol version: $protocol_version. Server supports: $supported_version",
        )
    end

    # Store client capabilities
    session.client_capabilities = get(params, "capabilities", Dict{String,Any}())

    # Store client info
    session.client_info = get(params, "clientInfo", Dict{String,Any}())

    # Mark session as initialized
    session.protocol_version = protocol_version
    session.state = INITIALIZED
    session.initialized_at = now()

    # Return initialization response
    return Dict{String,Any}(
        "protocolVersion" => supported_version,
        "capabilities" => session.server_capabilities,
        "serverInfo" => Dict{String,Any}("name" => "MCPRepl", "version" => get_version()),
    )
end

"""
    close_session!(session::MCPSession)

Close a session and clean up resources.
"""
function close_session!(session::MCPSession)
    if session.state == CLOSED
        @warn "Session already closed" session_id = session.id
        return
    end

    session.state = CLOSED
    session.closed_at = now()
    @info "Session closed" session_id = session.id duration =
        session.closed_at - session.created_at
end

"""
    get_session_info(session::MCPSession) -> Dict{String,Any}

Get information about the current session.
"""
function get_session_info(session::MCPSession)
    return Dict{String,Any}(
        "id" => session.id,
        "state" => string(session.state),
        "protocol_version" => session.protocol_version,
        "client_info" => session.client_info,
        "created_at" => session.created_at,
        "initialized_at" => session.initialized_at,
        "closed_at" => session.closed_at,
        "uptime" =>
            session.initialized_at === nothing ? nothing :
            (
                session.closed_at === nothing ? now() - session.initialized_at :
                session.closed_at - session.initialized_at
            ),
    )
end

"""
    get_version() -> String

Get the MCPRepl version string.
"""
function get_version()
    # Try to get version from parent module if available
    if isdefined(Main, :MCPRepl) && isdefined(Main.MCPRepl, :version_info)
        return Main.MCPRepl.version_info()
    end
    return "0.3.0"
end

end # module Session
