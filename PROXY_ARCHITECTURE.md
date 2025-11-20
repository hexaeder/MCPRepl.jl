# Persistent MCP Proxy Architecture Design

**Status**: Design Phase  
**Goal**: Stable agent connections during REPL restarts  
**Based On**: IPC branch prototype + multi-agent architecture

## Problem Statement

### Current Architecture Issues

1. **Connection Loss on REPL Restart**
   - When Revise fails to track changes, Julia needs restart
   - MCP server runs inside REPL process → restarts with REPL
   - AI agents lose connection and struggle to recover
   - Interrupts agent workflows

2. **Port Management Complexity**
   - Each project/agent needs unique port
   - Configuration scattered across multiple files
   - Port conflicts possible

3. **No Inter-Agent Communication**
   - Agents can't easily coordinate or share state
   - No built-in routing between agents
   - Manual coordination required

## Proposed Solution: MCP Proxy/Router

### Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    AI Agents / MCP Clients               │
│                                                          │
│   Agent 1        Agent 2        Agent 3       Claude    │
└────┬─────────────────┬──────────────┬──────────────┬────┘
     │                 │              │              │
     └─────────────────┴──────────────┴──────────────┘
                       │
                       │ Single Port (3000)
                       │
     ┌─────────────────▼────────────────────────────┐
     │                                               │
     │          Persistent MCP Proxy Server         │
     │                                               │
     │  • Always running (independent process)      │
     │  • Routes requests to backend REPLs          │
     │  • Buffers during REPL restarts              │
     │  • Manages sessions and context              │
     │                                               │
     └────┬──────────────────┬──────────────────┬───┘
          │                  │                  │
          │                  │                  │
     ┌────▼─────┐      ┌────▼─────┐      ┌────▼─────┐
     │          │      │          │      │          │
     │  REPL A  │      │  REPL B  │      │  REPL C  │
     │ Project1 │      │ Project2 │      │Supervisor│
     │ (Agent1) │      │ (Agent2) │      │          │
     │          │      │          │      │          │
     └──────────┘      └──────────┘      └──────────┘
       (restartable)    (restartable)     (restartable)
```

### Key Components

#### 1. Proxy Server Process
- **Lifecycle**: Started once, runs continuously
- **Independence**: Not tied to any specific project or REPL
- **Port**: Single port (e.g., 3000) for all connections
- **Implementation**: Separate Julia process or standalone daemon

#### 2. REPL Registry
```julia
struct REPLConnection
    id::String                  # Unique identifier (project name, agent name)
    pid::Union{Int, Nothing}   # Process ID for health monitoring
    status::Symbol              # :ready, :restarting, :failed, :stopped
    comm_channel::Channel       # Communication channel to REPL
    request_queue::Channel      # Buffered requests during restart
    metadata::Dict{String,Any}  # Project path, config, etc.
    last_heartbeat::DateTime    # For health monitoring
end

const REPL_REGISTRY = Dict{String, REPLConnection}()
```

#### 3. Routing Layer
```julia
function route_request(request::MCPRequest)
    # Extract target from request
    target_id = determine_target(request)
    
    # Look up REPL connection
    repl = get(REPL_REGISTRY, target_id, nothing)
    
    if repl === nothing
        return error_response("Unknown target: $target_id")
    end
    
    # Check REPL status
    if repl.status == :ready
        return forward_to_repl(repl, request)
    elseif repl.status == :restarting
        return buffer_request(repl, request)
    else
        return error_response("REPL unavailable: $(repl.status)")
    end
end
```

#### 4. Request Buffering
```julia
function buffer_request(repl::REPLConnection, request::MCPRequest)
    if length(repl.request_queue) >= MAX_QUEUE_SIZE
        return error_response("REPL busy, queue full")
    end
    
    put!(repl.request_queue, request)
    
    return pending_response(
        "REPL restarting, request queued (position: $(length(repl.request_queue)))"
    )
end

function drain_request_queue(repl::REPLConnection)
    @async begin
        while repl.status == :ready && !isempty(repl.request_queue)
            request = take!(repl.request_queue)
            try
                forward_to_repl(repl, request)
            catch e
                @error "Failed to drain queued request" exception=e
            end
        end
    end
end
```

## Design Decisions

### Decision 1: Request Routing Strategy

**Question**: How does proxy determine which REPL should handle each request?

**Options Considered**:

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **A. URL Path** <br> `/projects/myproject/tools/ex` | Clear, RESTful, explicit | Breaks MCP protocol, requires client changes | ❌ Rejected |
| **B. HTTP Header** <br> `X-MCPRepl-Target: agent-1` | MCP-compatible, flexible | Non-standard, requires client support | ⚠️ Possible |
| **C. Session-Based** <br> Connect to target, all requests routed there | Simple, stateful, no per-request overhead | Requires connection establishment protocol | ✅ **Recommended** |
| **D. Request Field** <br> `"_target": "project-a"` in params | MCP-compatible | Requires client awareness, messy | ⚠️ Fallback |

**Chosen: C - Session-Based Routing**

**Protocol**:
1. Client connects to proxy on port 3000
2. Client sends initialization request: `{"method": "mcprepl/connect", "params": {"target": "project-a"}}`
3. Proxy establishes session, maps connection → REPL
4. All subsequent requests on that connection route to same REPL
5. Client can disconnect and reconnect to different target

**Advantages**:
- No per-request routing overhead
- Clean separation of concerns
- Backward compatible (can fall back to header/param routing)
- Supports connection pooling

### Decision 2: REPL Communication Mechanism

**Question**: How does proxy communicate with backend REPLs?

**Options Considered**:

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **A. Distributed.jl** | Built-in, IPC branch prototype already uses | Requires same Julia version, shared environment | ⚠️ Phase 1 |
| **B. HTTP** | Language-agnostic, standard, debuggable | Each REPL needs HTTP server, overhead | ✅ **Phase 2** |
| **C. Named Pipes/Sockets** | Fast, OS-level, flexible | Platform-specific, complex error handling | ❌ Too complex |
| **D. Message Queue (ZMQ)** | Robust, proven, language-agnostic | External dependency, setup overhead | ❌ Overkill |

**Chosen: Progressive Enhancement**

**Phase 1 - Distributed.jl** (Quickest MVP):
```julia
# Proxy starts REPLs as workers
REPL_WORKER = addprocs(1)[1]

@spawnat REPL_WORKER begin
    # Load project, activate environment
    # Execute requests
end
```

**Phase 2 - HTTP** (Production-ready):
```julia
# Each REPL runs mini HTTP server on random port
# Proxy connects via HTTP, forwards MCP requests

# In REPL process:
start_repl_http_server(port) do request
    execute_mcp_tool(request)
end

# In Proxy:
HTTP.post("http://localhost:$(repl.port)/mcp", body=request_json)
```

### Decision 3: REPL Lifecycle Management

**Question**: Who starts/stops/restarts REPLs? Proxy or Supervisor?

**Options**:

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **A. Proxy manages REPLs** | Self-contained, simpler architecture | Duplicates supervisor logic, tight coupling | ❌ Wrong layer |
| **B. Supervisor manages REPLs** | Separation of concerns, already implemented | Proxy needs supervisor API | ✅ **Recommended** |
| **C. Hybrid** | Flexibility | Complexity, unclear ownership | ❌ Confusing |

**Chosen: B - Supervisor Manages REPLs**

**Rationale**:
- Supervisor already has agent lifecycle management
- Proxy should be routing layer, not process manager
- Clean separation: Supervisor = process management, Proxy = connection stability

**Integration Points**:
1. **Supervisor starts REPL** → **Registers with Proxy**
   ```julia
   # In Supervisor
   function start_agent(name)
       agent = spawn_agent_process(name)
       MCPRepl.Proxy.register_repl(name, agent.pid, agent.port)
   end
   ```

2. **Supervisor detects REPL restart needed** → **Notifies Proxy**
   ```julia
   # In Supervisor
   function restart_agent(name)
       MCPRepl.Proxy.mark_restarting(name)
       kill_agent_process(name)
       agent = spawn_agent_process(name)
       MCPRepl.Proxy.repl_ready(name, agent.pid, agent.port)
   end
   ```

3. **Proxy detects REPL unresponsive** → **Notifies Supervisor**
   ```julia
   # In Proxy health check
   if !Utils.process_running(repl.pid)
       Supervisor.handle_agent_failure(repl.id)
   end
   ```

### Decision 4: State Management

**Question**: Where does session/execution state live?

**Answer**: **Hybrid Approach**

**In Proxy**:
- Connection sessions (which client → which REPL)
- Request queues during restarts
- Routing metadata
- Health status

**In REPL**:
- REPL state (variables, modules, workspace)
- Execution history
- Revise tracking

**Rationale**: Proxy is stateless regarding execution, stateful regarding routing

### Decision 5: Configuration & Discovery

**Question**: How do clients know to connect to proxy? How to maintain backward compatibility?

**Strategy**: **Gradual Migration**

**Phase 1 - Opt-in Proxy Mode**:
```json
// In .mcprepl/proxy.json
{
  "enabled": true,
  "port": 3000,
  "targets": {
    "project-a": {"port": 3001},
    "project-b": {"port": 3002},
    "supervisor": {"port": 3003}
  }
}
```

If proxy enabled:
- Agents connect to port 3000 (proxy)
- Proxy routes to backend REPLs on 3001, 3002, 3003

If proxy disabled:
- Agents connect directly to REPL ports (current behavior)

**Phase 2 - Proxy by Default**:
- Proxy always runs
- Simplified config (single port)
- Backend REPL ports auto-assigned

## Implementation Phases

### Phase 1: MVP Proxy (Single REPL) 🎯 Current Goal

**Goal**: Prove the concept with simplest case

**Scope**:
- Proxy server that routes to ONE REPL
- Use Distributed.jl for communication
- Basic request forwarding
- No buffering yet, fail fast if REPL down

**Success Criteria**:
- Agent can connect to proxy
- Requests forward to backend REPL
- REPL restart doesn't crash proxy (connection stays alive)

**Timeline**: 1-2 weeks

**Tasks**:
1. Create `src/proxy.jl` with basic server
2. Session establishment protocol
3. Request forwarding via Distributed.jl
4. Integration test with one agent

### Phase 2: Request Buffering 🛡️

**Goal**: Handle REPL restarts gracefully

**Scope**:
- Detect when REPL is restarting
- Queue incoming requests
- Drain queue when REPL comes back
- Inform agents of queue status

**Success Criteria**:
- Agent sends request during REPL restart
- Request gets queued, not failed
- Agent receives pending response
- Request executes when REPL ready

**Timeline**: 1 week

**Tasks**:
1. Add REPLConnection status states
2. Implement request queue per REPL
3. Queue draining logic
4. Status notifications to clients

### Phase 3: Multi-REPL Routing 🌐

**Goal**: Support multiple projects on one port

**Scope**:
- Multiple REPL registrations
- Session-based routing
- Client can switch targets
- Health monitoring for all REPLs

**Success Criteria**:
- 3+ agents connect to proxy port 3000
- Each routes to different backend REPL
- All agents work simultaneously
- Agent can disconnect and reconnect to different REPL

**Timeline**: 2 weeks

**Tasks**:
1. Enhance REPL_REGISTRY to handle multiple REPLs
2. Implement target selection protocol
3. Per-connection session state
4. Health monitoring with `Utils.process_running()`

### Phase 4: Supervisor Integration 🤝

**Goal**: Supervisor manages REPLs, Proxy routes requests

**Scope**:
- Supervisor registers agents with proxy
- Proxy notifies supervisor of failures
- Coordinated restart workflow
- Unified configuration

**Success Criteria**:
- Start supervisor → all agents auto-register with proxy
- Agent REPL crashes → supervisor restarts, proxy buffers
- No manual proxy configuration needed

**Timeline**: 2 weeks

**Tasks**:
1. Supervisor → Proxy registration API
2. Proxy → Supervisor failure notification
3. Coordinated restart protocol
4. Configuration integration

### Phase 5: HTTP Backend (Production) 🚀

**Goal**: Replace Distributed.jl with HTTP for flexibility

**Scope**:
- Each REPL runs mini HTTP server
- Proxy forwards via HTTP
- Language-agnostic protocol
- Better error handling

**Success Criteria**:
- REPLs can be in different Julia versions
- REPLs can be on different machines (future)
- Improved debuggability
- Performance acceptable

**Timeline**: 2-3 weeks

**Tasks**:
1. Implement HTTP server in REPL process
2. Modify proxy to use HTTP client
3. Protocol documentation
4. Performance benchmarking

### Phase 6: Agent-to-Agent Communication 🤝

**Goal**: Enable coordination between agents

**Scope**:
- Agent discovery through proxy
- Message routing between agents
- Shared context/state (optional)
- Coordinator patterns

**Success Criteria**:
- Agent A can query Agent B's REPL
- Agent A can request Agent B perform task
- Supervisor can broadcast to all agents

**Timeline**: 3-4 weeks (future work)

## API Specifications

### Proxy HTTP API

#### Client → Proxy

**Connect to Target**:
```json
POST /
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "mcprepl/connect",
  "params": {
    "target": "project-a"
  }
}

Response:
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "session_id": "abc123",
    "target": "project-a",
    "status": "connected"
  }
}
```

**Execute Tool** (after connected):
```json
POST /
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "ex",
    "arguments": {
      "e": "2 + 2",
      "q": false
    }
  }
}

Response (if REPL ready):
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": "4"
}

Response (if REPL restarting):
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "status": "pending",
    "message": "REPL restarting, request queued",
    "queue_position": 3
  }
}
```

#### Supervisor → Proxy (Internal API)

**Register REPL**:
```julia
MCPRepl.Proxy.register_repl(
    id = "project-a",
    pid = 12345,
    port = 3001,  # or communication channel
    metadata = Dict("project_path" => "/path/to/project")
)
```

**Mark REPL Restarting**:
```julia
MCPRepl.Proxy.mark_restarting("project-a")
```

**REPL Ready**:
```julia
MCPRepl.Proxy.repl_ready(
    id = "project-a",
    pid = 12346,  # new PID
    port = 3001
)
```

#### Proxy → Supervisor (Internal API)

**Notify Failure**:
```julia
MCPRepl.Supervisor.handle_repl_failure(
    repl_id = "project-a",
    reason = "Process not responding"
)
```

### Configuration Schema

**`.mcprepl/proxy.json`**:
```json
{
  "enabled": true,
  "port": 3000,
  "max_queue_size": 100,
  "health_check_interval": 5,
  "backend_timeout": 30,
  "log_level": "info"
}
```

**`.mcprepl/agents.json`** (enhanced):
```json
{
  "supervisor": {
    "port": 3000,  // proxy port, not direct REPL port
    "proxy_enabled": true
  },
  "agents": {
    "agent-1": {
      "description": "Data analysis agent",
      "directory": "agents/data-agent",
      "proxy_target": "agent-1"  // target name for proxy routing
    }
  }
}
```

## Testing Strategy

### Unit Tests
- Request routing logic
- Queue management
- Session handling
- Health monitoring

### Integration Tests
- Proxy + single REPL
- Proxy + multiple REPLs
- Proxy + supervisor
- REPL restart scenarios

### Stress Tests
- 100+ queued requests
- Rapid REPL restarts
- Multiple simultaneous agents
- Long-running sessions

### User Acceptance Tests
- Agent workflow during REPL restart
- Multi-project setup
- Configuration simplicity

## Success Metrics

1. **Connection Stability**
   - Agents stay connected >99% during REPL restarts
   - < 100ms request routing overhead
   - Zero dropped requests (all queued or responded)

2. **User Experience**
   - Single port configuration (vs 3-5 currently)
   - Transparent REPL restarts
   - Clear status messages during restarts

3. **Reliability**
   - Proxy uptime >99.9%
   - Automatic recovery from REPL failures
   - No data loss during transitions

## Open Questions

1. **Proxy Deployment**: Separate process or integrated into supervisor?
2. **Authentication**: How to handle API keys with proxy in the middle?
3. **Observability**: Metrics, logging, debugging tools?
4. **Performance**: Will HTTP overhead be acceptable? Need benchmarks.
5. **Failure Modes**: What if proxy crashes? Fallback to direct connection?

## Next Steps

1. ✅ **Extracted `utils.jl`** (Complete)
2. 📝 **This design document** (Complete)
3. 🎯 **Phase 1 Prototype** (Next)
   - Create `src/proxy.jl`
   - Implement basic routing
   - Test with single REPL
4. 📊 **Validate Approach**
   - Does it solve the Revise restart problem?
   - Performance acceptable?
   - Agent experience improved?
5. 🔄 **Iterate Based on Feedback**

## References

- IPC Branch: `feature/ipc-process-separation` (prototype reference)
- Multi-Agent Work: Current `main` branch (process management)
- MCP Spec: https://modelcontextprotocol.io/
- Supervisor Pattern: Already implemented in `src/MCPRepl.jl`
