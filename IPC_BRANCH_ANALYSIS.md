# IPC Branch Analysis (feature/ipc-process-separation)

**Branch Status**: Diverged from main at commit `72d6aff` (Nov 5, 2025)  
**Commits**: 2 total commits  
**Current Status**: Early prototype of persistent MCP proxy architecture

## Vision: Persistent MCP Proxy/Router

The IPC branch is an early prototype exploring a **persistent MCP server that acts as a proxy/router** to backend REPL processes. This solves a critical problem with the current architecture:

### The Problem

**Current**: MCP server runs inside each Julia REPL process
- ❌ When Julia needs restart (Revise failures), MCP server goes down
- ❌ Agents lose connection and struggle to recover
- ❌ Each project needs separate port configuration
- ❌ No built-in routing between multiple REPLs/agents

### The Solution (IPC Branch Vision)

**Future**: Persistent MCP proxy server + multiple backend REPL processes
- ✅ MCP server runs in separate, stable process (never restarts)
- ✅ Agents stay connected even when backend REPLs restart
- ✅ Single server can route to multiple projects on one port
- ✅ Enables proper agent-to-agent communication
- ✅ Supervisor becomes routing layer, not just process manager

## Architecture Evolution

### Current Architecture (Post Multi-Agent Merge)
```
Agent 1 → [MCP Server + REPL Process] Port 3001
Agent 2 → [MCP Server + REPL Process] Port 3002
Supervisor → [MCP Server + REPL Process] Port 3000

Problems:
- 3 separate MCP servers
- REPL restart = connection loss
- No inter-agent routing
```

### IPC Branch Prototype (Initial Step)
```
Agent → [MCP Server Process] → [REPL Worker Process]
                Port 3000        (via Distributed.jl)

Improvements:
- MCP server decoupled from REPL
- REPL can restart without dropping connections
- Single server instance (but only 1 REPL supported)
```

### Future Vision (Complete Architecture)
```
Multiple Agents → [Persistent MCP Proxy/Router] → Multiple REPL Processes
                           Port 3000                   ├─ Project A (Agent 1)
                                                       ├─ Project B (Agent 2)  
                                                       └─ Supervisor REPL

Capabilities:
- One server, one port, multiple projects
- REPLs restart independently, agents stay connected
- Server routes requests by project/agent context
- Agent-to-agent communication through proxy
- Buffer requests during REPL restarts
```

## Why This Complements Multi-Agent

The multi-agent work and IPC work are **synergistic**, not conflicting:

1. **Multi-agent**: Solved process isolation, agent management, configuration
2. **IPC/Proxy**: Solves connection stability, routing, and unified interface

Combined architecture:
- Supervisor manages agent lifecycles (multi-agent contribution)
- Persistent proxy provides stable MCP interface (IPC contribution)
- Agents can restart REPLs without losing AI agent connections
- Single port serves all projects, proxy handles routing

## Commit 1: Refactor security configuration and add utility functions (7268375)

**Date**: Nov 5, 2025  
**Changes**: Code reorganization + new utilities

### New Files Created

#### `src/tool_defintions.jl` (typo in filename)
- **Size**: 1,383 lines
- **Purpose**: Moved all tool definitions from `MCPRepl.jl` to separate file
- **Content**: Same tool definitions, just relocated for organization
- **Assessment**: **Low value** - main already has tools in MCPRepl.jl and this introduces a typo

#### `src/utils.jl`
- **Size**: 22 lines  
- **Purpose**: Cross-platform process checking utility
- **Content**:
  ```julia
  module Utils
  
  """
      process_running(pid::Int) -> Bool
  
  Check if a process with the given PID is currently running.
  """
  function process_running(pid::Int)
      if Sys.iswindows()
          # On Windows, use tasklist to check for PID
          return read(`tasklist /FI "PID eq $pid"`, String) |> strip |> !isempty
      else
          # On Unix-like systems (Linux, macOS), use kill -0
          return success(`kill -0 $pid`)
      end
  end
  
  end # module Utils
  ```
- **Assessment**: **POTENTIALLY USEFUL** - Could be valuable for supervisor process monitoring

### Modified Files

- **`Project.toml`**: Added `Distributed` dependency
- **`src/security.jl`**: Minor formatting change
- **`src/MCPServer.jl`**: Tool loading refactored to use `tool_defintions.jl`
- **`src/MCPRepl.jl`**: 1,386 lines deleted (moved to tool_defintions.jl)

## Commit 2: Refactor MCPRepl startup and distributed architecture (157ed11)

**Date**: Nov 5, 2025  
**Changes**: Introduced worker process architecture + tests

### Architecture Changes

#### `.julia-startup.jl`
**Before** (from templates branch):
```julia
using Pkg
Pkg.activate(".")

# Load Revise, then MCPRepl
# Check for supervisor/agent mode and configure accordingly
# Call MCPRepl.start!() with appropriate parameters
```

**After** (IPC branch):
```julia
using Pkg
Pkg.activate(".")

try
    using Revise
    @info "✓ Revise loaded"
catch e
    @info "ℹ Revise not loaded"
end

using MCPRepl

# Automatically start with worker process
if isinteractive()
    try
        @async MCPRepl.start!()
    catch e
        @warn "Could not start MCPRepl server"
    end
end
```

**Assessment**: Much simpler but **removes all multi-agent/supervisor support**

#### `repl` script
**Before**: ~200 lines supporting `--supervisor`, `--agent NAME`, multi-agent config  
**After**: ~100 lines, **removed all multi-agent support**, basic REPL launcher only

#### `src/MCPRepl.jl` - `start!()` function
**Before** (current main):
```julia
function start!(;
    port::Union{Int,Nothing}=nothing,
    verbose::Bool=true,
    security_mode::Union{Symbol,Nothing}=nothing,
    supervisor::Bool=false,
    agents_config::String=".mcprepl/agents.json",
    agent_name::String="",
    workspace_dir::String=pwd(),
)
    # Load security config (handles agent/supervisor modes)
    # Start supervisor if requested
    # Start agent heartbeat if in agent mode
    # Configure and start HTTP server
    # Show status
end
```

**After** (IPC branch):
```julia
const REPL_WORKER = Ref{Union{Int, Nothing}}(nothing)

function start!(; verbose::Bool = true)
    if REPL_WORKER[] !== nothing && REPL_WORKER[] in workers()
        @info "MCPRepl worker already running"
        return
    end
    
    @info "Starting MCPRepl worker process..."
    REPL_WORKER[] = addprocs(1)[1]
    
    @spawnat REPL_WORKER[] begin
        using Pkg
        Pkg.activate(project_path)
        using Revise
        using MCPRepl
        @info "Worker process environment is ready."
    end
    
    # Load security config
    # Wrap ex tool to use remotecall_fetch(REPL_WORKER[])
    # Start HTTP server on main process
end
```

**Assessment**: **Incompatible** with multi-agent architecture, removes all supervisor/agent support

### New Test Files

#### `test/distributed_test.jl` (51 lines)
Tests worker process isolation:
```julia
@testset "Worker process isolation" begin
    # Test that worker has separate environment
    # Test that code runs on worker not main
    # Test error handling
end
```

#### `test/process_separation_test.jl` (117 lines)
Tests IPC communication:
```julia
@testset "Process separation and IPC" begin
    # Test worker startup
    # Test remote execution
    # Test server lifecycle
    # Test error propagation
end
```

**Assessment**: Tests for architecture that conflicts with current main

## Key Insights

### What This Branch Was Actually Trying to Solve

1. **Connection Stability**: Keep MCP server alive when REPL needs restart
2. **Agent Resilience**: Agents shouldn't lose connection when Revise fails
3. **Unified Interface**: Single MCP endpoint that can route to multiple REPLs
4. **REPL Independence**: Server process separate from execution environment

### How It Relates to Multi-Agent Work

**They're complementary layers**:

**Multi-Agent (Process Management Layer)**:
- Manages agent lifecycles (start, stop, restart)
- Handles per-agent configuration and projects
- Provides supervisor pattern for orchestration
- Already merged and working

**IPC/Proxy (Connection Stability Layer)**:
- Provides persistent MCP interface
- Routes requests to appropriate REPL/agent
- Buffers requests during REPL restarts
- Enables inter-agent communication
- Still being developed

**Combined**: Supervisor manages agents → Proxy routes MCP requests → Each agent's REPL executes code

### What to Extract and Build Upon

#### 1. `src/utils.jl` - Process Checking Utility ✅ IMMEDIATE VALUE

The `process_running(pid)` function is immediately useful for supervisor health monitoring:

```julia
# In supervisor health check
if !Utils.process_running(agent.pid)
    @warn "Agent $(agent.name) process not responding, restarting..."
    restart_agent(agent.name)
end
```

**Action**: Add to main immediately, use in supervisor.

#### 2. Proxy/Router Pattern 🎯 CORE CONCEPT

The IPC branch prototype shows the basic pattern, but needs expansion:

**Current prototype** (single REPL):
```julia
const REPL_WORKER = Ref{Union{Int, Nothing}}(nothing)

# Wrap tool to delegate to worker
new_tools[ex_tool_idx] = @mcp_tool(...,
    function(args)
        result = remotecall_fetch(REPL_WORKER[]) do
            MCPRepl.execute_repllike(code)
        end
        return result
    end
)
```

**Needed expansion** (multiple REPLs with routing):
```julia
const REPL_REGISTRY = Dict{String, REPLConnection}()

# Route based on context (project, agent, etc.)
function route_request(request::MCPRequest)
    target = determine_target(request)  # Which REPL?
    repl = REPL_REGISTRY[target]
    
    if !repl.alive
        return buffered_response("REPL restarting, please wait...")
    end
    
    return forward_to_repl(repl, request)
end
```

**Action**: Design full routing architecture, implement incrementally.

#### 3. Connection Buffering Pattern 🎯 KEY FEATURE

When REPL restarts, proxy should buffer/queue requests:

```julia
struct REPLConnection
    id::String
    process::Union{Process, Nothing}
    status::Symbol  # :ready, :restarting, :failed
    request_queue::Channel{MCPRequest}
end

function handle_request_while_restarting(repl::REPLConnection, request)
    if length(repl.request_queue) < MAX_QUEUE_SIZE
        put!(repl.request_queue, request)
        return pending_response("REPL restarting, request queued")
    else
        return error_response("REPL unavailable, queue full")
    end
end
```

**Action**: Implement request buffering for graceful REPL restarts.

#### 4. Test Patterns for Distributed Architecture ✅ USEFUL

The distributed tests show good patterns to adapt:

```julia
@testset "Proxy routing and failover" begin
    # Start proxy server
    # Start multiple backend REPLs
    # Send requests, verify correct routing
    # Kill a REPL, verify buffering
    # Restart REPL, verify queue drains
    # Test inter-agent message routing
end
```

**Action**: Create new test suite for proxy/router architecture.

## Implementation Roadmap

### Phase 1: Immediate (Extract Utilities) ✅

1. **Add `src/utils.jl`** with process monitoring
2. **Integrate into Supervisor** for health checks
3. **Test with current multi-agent setup**

```bash
git checkout main
# Create src/utils.jl
git add src/utils.jl
git commit -m "Add process monitoring utilities for supervisor health checks"
```

### Phase 2: Foundation (Proxy Server Core) 🔨

1. **Design routing protocol**: How to specify target REPL in MCP request?
   - URL path? `/projects/myproject/tools/ex`
   - Header? `X-MCPRepl-Target: project-a`
   - Request field? `"_target": "agent-1"`

2. **Implement basic proxy server**:
   - Persistent process (not tied to any REPL)
   - Accept MCP requests on single port (e.g., 3000)
   - Maintain registry of backend REPL connections
   - Route requests to appropriate REPL

3. **Connection management**:
   - Track REPL process PIDs and health status
   - Detect when REPL restarts needed
   - Coordinate graceful restarts

### Phase 3: Resilience (Buffering & Recovery) 🛡️

1. **Request buffering**:
   - Queue requests when REPL is restarting
   - Configurable queue size and timeout
   - Drain queue when REPL comes back online

2. **Status reporting**:
   - Expose REPL health status to agents
   - Inform agents when REPL is restarting
   - Provide ETA for REPL availability

3. **Graceful degradation**:
   - Read-only mode during restart?
   - Cached responses for idempotent queries?
   - Fallback to alternative REPLs?

### Phase 4: Multi-Project (Unified Interface) 🌐

1. **Project registry**:
   - Multiple projects on one port
   - Dynamic REPL registration/deregistration
   - Project-based routing

2. **Integration with supervisor**:
   - Supervisor registers each agent's REPL with proxy
   - Proxy becomes the stable MCP endpoint
   - Agents connect to proxy, not individual REPLs

3. **Configuration simplification**:
   - One port in agent configs (proxy port)
   - Proxy routes based on agent identity
   - No per-project port management

### Phase 5: Advanced (Agent-to-Agent) 🤝

1. **Inter-agent messaging**:
   - Route requests between agents
   - Agent discovery through proxy
   - Shared context/state management

2. **Coordinator pattern**:
   - One agent coordinates others
   - Proxy facilitates communication
   - Supervisor monitors overall health

## Technical Challenges to Solve

### 1. Request Routing Strategy

**Question**: How does proxy know which REPL should handle each request?

**Options**:
- **Explicit target**: Agent specifies target in request metadata
- **Connection context**: Each agent connection bound to specific REPL
- **Project inference**: Parse request content to determine project
- **Session-based**: Agent establishes session, all requests routed there

**Recommended**: Connection context + session-based (simplest, most reliable)

### 2. REPL Restart Detection

**Question**: How does proxy know when REPL needs/wants to restart?

**Options**:
- **Signal-based**: REPL sends "restarting" message before exit
- **Health check**: Proxy polls REPL, detects unresponsive
- **Process monitoring**: Watch REPL PID with `process_running()`
- **Explicit API**: `MCPRepl.restart_repl()` notifies proxy first

**Recommended**: Combination of explicit API + process monitoring (belt and suspenders)

### 3. Communication Mechanism

**Question**: How does proxy communicate with backend REPLs?

**Current IPC branch**: Distributed.jl (requires same Julia version, shared package env)

**Alternatives**:
- **HTTP**: REPLs run mini HTTP servers, proxy forwards HTTP requests
- **Named pipes/sockets**: OS-level IPC (more complex, but flexible)
- **ZMQ/nanomsg**: Message queue (adds dependency)
- **Julia RPC**: Keep Distributed.jl (simplest, but limiting)

**Recommended**: Start with Distributed.jl, migrate to HTTP for flexibility

### 4. State Management

**Question**: Where does session state live?

**Options**:
- **In REPL**: Proxy is truly stateless (requires reconnection on restart)
- **In Proxy**: Proxy maintains session, replays to new REPL (complex)
- **Hybrid**: Critical state in proxy, rest in REPL

**Recommended**: Hybrid - proxy tracks routing/connection, REPL owns execution state

## Migration Path

### Current State (After Multi-Agent Merge)
```
Agent → Direct MCP connection → REPL (port 3001)
```

### Step 1: Proxy for Single REPL (IPC Branch Baseline)
```
Agent → Proxy (port 3000) → REPL Worker (Distributed.jl)
```

### Step 2: Proxy with Multiple REPLs
```
Agent 1 → Proxy (port 3000) → REPL A (HTTP)
Agent 2 →                   → REPL B (HTTP)
```

### Step 3: Integrated with Supervisor
```
Agents → Proxy (port 3000) → [Supervisor manages] → REPL A, B, C...
```

### Step 4: Inter-Agent Communication
```
Agent 1 ⟷ Proxy ⟷ Agent 2
           ↓
       [REPLs A, B, C]
```

## Recommended Next Steps

1. **Resolve current rebase** ✅ (Done - aborted, understood vision)

2. **Extract `src/utils.jl`** ✅ (Ready to commit)

3. **Document proxy architecture** 📝 (This document is the start)

4. **Design routing protocol** 🎯 (Critical design decision)
   - How do agents specify target?
   - How does proxy map requests to REPLs?
   - What about backward compatibility?

5. **Prototype basic proxy** 🔨 (MVP implementation)
   - Single port accepts MCP requests
   - Routes to one backend REPL
   - Test with current multi-agent setup

6. **Iterate based on feedback** 🔄
   - Does it solve the Revise restart problem?
   - Can agents stay connected?
   - Performance acceptable?

## Conclusion

The IPC branch is an **early prototype of a critical architectural evolution**, not an abandoned experiment. It represents the first step toward:

- ✅ Stable agent connections during REPL restarts
- ✅ Unified MCP interface across multiple projects
- ✅ Simplified port configuration
- ✅ Foundation for agent-to-agent communication

**Status**: Promising direction, needs design work before implementation

**Action**: 
1. ✅ Extract `src/utils.jl` immediately
2. 📝 Design complete routing architecture
3. 🔨 Implement proxy server incrementally
4. 🔄 Iterate with multi-agent integration
5. ⏸️ Keep IPC branch as reference, don't delete
