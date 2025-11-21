"""
Proxy Tool Definitions

MCP tools provided by the proxy server for session and system management.
"""

# ============================================================================
# Tool Definition Infrastructure
# ============================================================================

struct MCPTool
    id::Symbol
    name::String
    description::String
    parameters::Dict{String,Any}
    handler::Function
end

macro mcp_tool(id, description, params, handler)
    if !(id isa QuoteNode || (id isa Expr && id.head == :quote))
        error("@mcp_tool requires a symbol literal for id, got: $id")
    end

    id_sym = id isa QuoteNode ? id.value : id.args[1]
    name_str = string(id_sym)

    return esc(
        quote
            MCPTool(
                $(QuoteNode(id_sym)),
                $name_str,
                $description,
                $params,
                $handler,
            )
        end,
    )
end

# ============================================================================
# Proxy Tools
# ============================================================================

"""
Help tool - provides comprehensive information about the MCPRepl proxy system
"""
const HELP_TOOL = @mcp_tool :help "Get comprehensive information about the MCPRepl proxy system, its architecture, and how to use it" Dict(
    "type" => "object",
    "properties" => Dict(),
    "required" => []
) (args) -> begin
    """
    # MCPRepl Proxy System

    ## Architecture
    The MCPRepl proxy is a persistent MCP server that routes requests to multiple Julia execution sessions (backends). It provides:
    - Session management with MCP-compliant session IDs
    - Dynamic Julia session spawning and lifecycle management
    - Request routing to appropriate backend sessions
    - Real-time monitoring dashboard
    - Proxy-level tools for system management

    ## Workflow
    1. **Initialize**: MCP client connects and receives a session ID
    2. **Discover**: Use `list_julia_sessions` to see available sessions
    3. **Start**: Use `start_julia_session` to spawn new Julia backends
    4. **Execute**: Call Julia tools (ex, eval, etc.) - routed to backend
    5. **Monitor**: Access dashboard at http://localhost:3000/dashboard

    ## Available Tools
    - **help**: This comprehensive guide
    - **proxy_status**: Current proxy status and connected sessions
    - **list_julia_sessions**: List all Julia execution sessions
    - **start_julia_session**: Spawn a new Julia backend
    - **dashboard_url**: Get monitoring dashboard link

    When a Julia session is connected, additional Julia-specific tools become available (code execution, introspection, LSP features, etc.).

    ## Session Management
    Each MCP client receives a unique session ID on initialization. Sessions can be associated with specific Julia backends using the X-MCPRepl-Target header, or remain at proxy-level for management operations.

    ## Getting Started
    1. Call `list_julia_sessions` to see if any sessions exist
    2. If none exist, call `start_julia_session` with a project path
    3. Once started, Julia tools become available automatically
    4. Use `dashboard_url` to access real-time monitoring
    """
end

"""
Proxy status tool - shows current proxy state and connected sessions
"""
const PROXY_STATUS_TOOL = @mcp_tool :proxy_status "Get the status of the MCP proxy server and connected REPL backends" Dict(
    "type" => "object",
    "properties" => Dict(),
    "required" => []
) (args, repls) -> begin
    num_repls = length(repls)
    status_text = "MCP Proxy Status:\n- Port: 3000\n- Connected agents: $num_repls\n- Status: Running\n- Dashboard: http://localhost:3000/dashboard"
    if num_repls == 0
        status_text *= "\n\nNo backend REPL agents are currently connected. Start a backend REPL to enable Julia tools."
    else
        status_text *= "\n\nConnected agents:\n"
        for repl in repls
            status_text *= "  - $(repl.id) (port $(repl.port), status: $(repl.status))\n"
        end
    end
    status_text
end

"""
List Julia sessions tool - shows all registered execution sessions
"""
const LIST_JULIA_SESSIONS_TOOL = @mcp_tool :list_julia_sessions "List all registered Julia execution sessions and their connection status" Dict(
    "type" => "object",
    "properties" => Dict(),
    "required" => []
) (args, repls) -> begin
    if isempty(repls)
        """
        No Julia sessions currently registered.

        To connect a Julia session:
        1. Start a Julia session with MCPRepl
        2. It will automatically register with this proxy
        3. Julia tools will become available
        """
    else
        agent_text = "Connected Julia sessions ($(length(repls))):\n\n"
        for repl in repls
            pid_str = repl.pid === nothing ? "N/A" : string(repl.pid)
            agent_text *= "**$(repl.id)**\n"
            agent_text *= "  - Port: $(repl.port)\n"
            agent_text *= "  - PID: $pid_str\n"
            agent_text *= "  - Status: $(repl.status)\n"
            agent_text *= "  - Last heartbeat: $(repl.last_heartbeat)\n\n"
        end
        agent_text
    end
end

"""
Dashboard URL tool - provides link to monitoring dashboard
"""
const DASHBOARD_URL_TOOL = @mcp_tool :dashboard_url "Get the URL to access the monitoring dashboard" Dict(
    "type" => "object",
    "properties" => Dict(),
    "required" => []
) (args) -> begin
    """
    Dashboard URL: http://localhost:3000/dashboard

    The dashboard provides real-time monitoring of:
    - Connected Julia sessions
    - Tool calls and code execution
    - Event logs and metrics
    - Session status and heartbeats
    """
end

"""
Start Julia session tool - spawns a new Julia backend process
"""
const START_JULIA_SESSION_TOOL = @mcp_tool :start_julia_session "Start a new Julia execution session for a specific project. The session will register with the proxy and provide Julia tools." Dict(
    "type" => "object",
    "properties" => Dict(
        "project_path" => Dict(
            "type" => "string",
            "description" => "Path to the Julia project directory (containing Project.toml)"
        ),
        "session_name" => Dict(
            "type" => "string",
            "description" => "Optional name for the Julia session (defaults to project directory name)"
        )
    ),
    "required" => ["project_path"]
) (args, repls, list_repls_fn) -> begin
    # This tool needs special handling in proxy.jl due to process spawning
    # Handler will be called from proxy request handler
    # Return value indicates this is a special tool
    :start_julia_session_special
end

# ============================================================================
# Tool Registry
# ============================================================================

const PROXY_TOOLS = Dict{String,MCPTool}(
    "help" => HELP_TOOL,
    "proxy_status" => PROXY_STATUS_TOOL,
    "list_julia_sessions" => LIST_JULIA_SESSIONS_TOOL,
    "dashboard_url" => DASHBOARD_URL_TOOL,
    "start_julia_session" => START_JULIA_SESSION_TOOL,
)

"""
    get_proxy_tool_schemas() -> Vector{Dict}

Get MCP tool schema definitions for all proxy tools.
"""
function get_proxy_tool_schemas()
    return [
        Dict(
            "name" => tool.name,
            "description" => tool.description,
            "inputSchema" => tool.parameters
        )
        for tool in values(PROXY_TOOLS)
    ]
end
