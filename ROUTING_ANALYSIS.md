# Multi-Agent Routing Analysis

## Question
If I have only one proxy server running, but I might have multiple agents and multiple REPLs, how does the association between agent and REPL (routed by proxy) get established and maintained?

## Current Implementation

The proxy uses `REPL_REGISTRY` (Dict{String, REPLConnection}) where:
- **Key**: Unique REPL ID (e.g., "agent-1", "project-x")
- **Value**: Connection info (port, pid, status, metadata)

### Routing Method
Proxy determines which REPL to route to via the `X-MCPRepl-Target` header:

```
Client → Proxy (port 3000) + Header: X-MCPRepl-Target: "agent-1"
  ↓
Proxy looks up "agent-1" in REPL_REGISTRY
  ↓
Forwards to REPL at port specified in registry (e.g., 3006)
```

**If no header**: Routes to first available REPL (unpredictable with multiple REPLs)

## The Problem

**Issue**: Standard MCP clients (Claude Desktop, VS Code) don't support custom HTTP headers

**Result**: Can't reliably route to specific REPLs without client modifications

## Solutions Comparison

| Solution | Standard MCP | Multi-Client | Complexity | Status |
|----------|--------------|--------------|------------|---------|
| Custom Header | ❌ No | ✅ Yes | Low | ✅ Implemented |
| Path-based `/agent-1` | ⚠️ Partial | ✅ Yes | Low | 💡 Proposed |
| Port-per-REPL | ✅ Yes | ✅ Yes | Medium | ⭕ Alternative |
| Session Sticky | ✅ Yes | ⚠️ Maybe | High | ❌ Complex |
| Tool Namespace | ✅ Yes | ❌ No | Medium | ❌ Wrong model |

## Recommended: Path-Based Routing

Add path prefix to identify target REPL:

```julia
# Client configs:
"agent-1": "http://localhost:3000/agent-1"
"agent-2": "http://localhost:3000/agent-2"

# Proxy extracts agent ID from path, strips it, forwards request
/agent-1/tools/list → (route to agent-1) → /tools/list
```

**Advantages:**
- Works with standard MCP clients
- Single proxy port
- Clear client configuration
- Simple implementation

**Implementation Needed:**
```julia
function determine_target(req::HTTP.Request)
    # Check header first (backwards compatible)
    header = HTTP.header(req, "X-MCPRepl-Target")
    if !isempty(header)
        return String(header)
    end
    
    # Check URL path: /agent-id/...
    if (m = match(r"^/([^/]+)/", req.target)) !== nothing
        agent_id = m.captures[1]
        if haskey(REPL_REGISTRY, agent_id)
            # Strip agent prefix from path
            req.target = replace(req.target, r"^/[^/]+" => "")
            return agent_id
        end
    end
    
    # Default: first available
    repls = list_repls()
    return isempty(repls) ? nothing : first(repls).id
end
```

## Registration & Lifecycle

### REPL Startup
```julia
# Backend REPL registers itself:
register_repl(
    "agent-1",           # Unique ID
    port=3006,           # Where REPL MCP server listens
    pid=12345,
    metadata=Dict(
        "workspace" => "/path/to/project",
        "agent_name" => "CodeHelper"
    )
)
```

### Health Monitoring
- REPLs send heartbeat every 5 seconds
- Proxy tracks `last_heartbeat`, `missed_heartbeats`, `status`
- Dashboard displays live agent status

### Client Connection
```jsonc
// .vscode/mcp.json
{
  "servers": {
    "julia-agent-1": {
      "type": "http",
      "url": "http://localhost:3000/agent-1"  // Path-based
    }
  }
}
```

## Dashboard Integration

The dashboard already supports multi-agent:
- Shows all registered REPLs in sidebar
- Events tagged with agent `id`
- Per-agent filtering and logs
- Real-time status monitoring

**Dashboard does NOT control routing** - that's determined by:
1. Client configuration (which URL/path they connect to)
2. Proxy routing logic (header or path-based)

## Action Items

1. **Implement path-based routing** in proxy.jl
2. **Document client configuration** for multi-agent setups
3. **Test with multiple REPLs** running simultaneously
4. **Update dashboard** to show routing information
5. **Consider**: UI to help users configure agent → REPL mappings
