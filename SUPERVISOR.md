# MCPRepl Supervisor Mode

A multi-agent process orchestration system for managing Julia REPL agents.

## Overview

Supervisor mode enables MCPRepl to manage multiple Julia REPL agent processes, monitoring their health, automatically restarting failed agents, and providing lifecycle management through MCP tools.

## Features

- **Heartbeat Monitoring**: Agents send periodic heartbeats to report their status
- **Automatic Restart**: Failed agents are automatically restarted based on policy
- **Force Kill**: Zombie processes can be forcefully terminated
- **Agent Lifecycle**: Start, stop, and restart agents on demand
- **Status Reporting**: Get detailed status of all managed agents

## Quick Start

### 1. Create Agents Configuration

Create a `.mcprepl/agents.json` file (copy from `agents.json.example`):

```json
{
  "supervisor": {
    "mode": "lax",
    "host": "127.0.0.1",
    "port": 3000,
    "api_keys": [],
    "allowed_ips": [],
    "heartbeat_interval_seconds": 1,
    "heartbeat_timeout_count": 5,
    "max_restarts_per_hour": 10
  },
  "agents": {
    "test-fixer": {
      "mode": "lax",
      "host": "127.0.0.1",
      "port": 3001,
      "api_keys": [],
      "allowed_ips": [],
      "directory": "agents/test-fixer",
      "description": "Analyzes test failures and iteratively fixes issues",
      "auto_start": true,
      "restart_policy": "always"
    },
    "performance-optimizer": {
      "mode": "relaxed",
      "host": "127.0.0.1",
      "port": 3002,
      "api_keys": ["change-me-secret-key"],
      "allowed_ips": [],
      "directory": "agents/performance-optimizer",
      "description": "Profiles code and suggests performance improvements",
      "auto_start": true,
      "restart_policy": "on_failure"
    }
  }
}
```

**Note**: Each supervisor and agent has its own security configuration with mode (lax/relaxed/strict), host binding, API keys, and IP allowlists. See the full `agents.json.example` for more examples including strict mode.

### 2. Create Agent Directories

Create agent directories with standard MCPRepl project structure:

```bash
mkdir -p agents/test-fixer/src
mkdir -p agents/performance-optimizer/src
```

Each agent directory should contain:
- `Project.toml` - Julia project file
- `src/` - Agent source code

**Note**: Agents use the shared `.julia-startup.jl` from the project root, not individual startup scripts.

### 3. Launch Agents

The unified `repl` script in the project root handles all modes:

**Start supervisor:**
```bash
./repl --supervisor
```

**Start an agent:**
```bash
./repl --agent test-fixer
./repl --agent performance-optimizer
```

**Normal mode:**
```bash
./repl
```

The `repl` script automatically:
- Reads `.mcprepl/agents.json` configuration
- Sets environment variables (`JULIA_MCP_PORT`, `JULIA_MCP_AGENT_NAME`)
- Changes to agent directory (in agent mode)
- Starts Julia with agent-specific Project.toml
- Loads shared `.julia-startup.jl` which detects mode and starts heartbeats (in agent mode)

### 4. How It Works

When you start an agent with `./repl --agent test-fixer`:

1. Script reads `.mcprepl/agents.json` and extracts agent configuration
2. Sets `JULIA_MCP_PORT=3001`, `JULIA_MCP_AGENT_NAME=test-fixer`
3. Changes to `agents/test-fixer/`
4. Starts Julia with agent's Project.toml, loads project root's `.julia-startup.jl`
5. Startup script detects agent mode (via `JULIA_MCP_AGENT_NAME` env var)
6. Starts MCP server with agent's security config from agents.json
7. Begins heartbeat loop sending to supervisor every second

The supervisor monitors heartbeats and automatically restarts agents that become unresponsive

## Agent Configuration

### Supervisor Settings

```json
{
  "supervisor": {
    "mode": "lax",                      // Security mode: "lax", "relaxed", or "strict"
    "host": "127.0.0.1",                // Bind address
    "port": 3000,                       // Supervisor MCP server port
    "api_keys": [],                     // Required API keys (empty for lax mode)
    "allowed_ips": [],                  // IP allowlist (empty for lax/relaxed)
    "heartbeat_interval_seconds": 1,    // How often to check for heartbeats
    "heartbeat_timeout_count": 5,       // Missed heartbeats before declaring dead
    "max_restarts_per_hour": 10         // Rate limit for restarts
  }
}
```

### Agent Settings

```json
{
  "agent-name": {
    "mode": "lax",                      // Security mode for this agent
    "host": "127.0.0.1",                // Bind address for agent's MCP server
    "port": 3001,                       // Port for agent's MCP server
    "api_keys": [],                     // Required API keys for this agent
    "allowed_ips": [],                  // IP allowlist for this agent
    "directory": "agents/agent-name",   // Agent's working directory
    "description": "What this agent does",
    "auto_start": true,                 // Start automatically with supervisor
    "restart_policy": "always",         // "always", "on_failure", or "never"
    "supervisor_host": "localhost",     // Optional: supervisor host (default: localhost)
    "supervisor_port": 3000             // Optional: supervisor port (default: 3000)
  }
}
```

### Security Modes

- **`lax`**: No authentication, localhost only (127.0.0.1)
- **`relaxed`**: API key required, localhost only
- **`strict`**: API key required, IP allowlist enforced, can bind to any interface

### Restart Policies

- **`always`**: Restart agent whenever it stops (normal or failure)
- **`on_failure`**: Only restart if agent crashes/becomes unresponsive
- **`never`**: Never automatically restart (manual only)

## Heartbeat Protocol

Agents must send periodic heartbeats to the supervisor using JSON-RPC:

```json
{
  "jsonrpc": "2.0",
  "method": "supervisor/heartbeat",
  "id": 1,
  "params": {
    "agent_name": "test-fixer",
    "pid": 12345,
    "status": "healthy",
    "timestamp": "2025-11-02T18:48:00Z"
  }
}
```

**Note**: The heartbeat protocol is automatically handled by the shared `.julia-startup.jl` when running in agent mode. You don't need to manually implement heartbeats in your agent code.

The startup script automatically:
1. Detects agent mode via `JULIA_MCP_AGENT_NAME` environment variable
2. Reads supervisor configuration from `.mcprepl/agents.json`
3. Starts a background task that sends heartbeats every second
4. Silently ignores failures (in case supervisor isn't running yet)

If you need to customize the heartbeat behavior, you can inspect the heartbeat implementation in `.julia-startup.jl`.

## MCP Tools

When supervisor mode is enabled, these MCP tools become available:

### `supervisor_status`

Get status of all managed agents.

**Returns:**
```
Agent Status Report
============================================================

Agent: test-fixer
  Status: healthy
  Port: 3001
  PID: 12345
  Directory: agents/test-fixer
  Description: Analyzes and fixes test failures
  Uptime: 2h 15m
  Last Heartbeat: 1s ago
  Missed Heartbeats: 0
  Restarts: 0
  Restart Policy: always

Agent: performance-optimizer
  Status: dead
  Port: 3002
  PID: unknown
  Directory: agents/performance-optimizer
  Description: Profiles code and optimizes performance
  Uptime: not started
  Last Heartbeat: 7s ago
  Missed Heartbeats: 7
  Restarts: 2
  Restart Policy: on_failure
```

### `supervisor_start_agent`

Start a managed agent process.

**Parameters:**
- `agent_name` (string, required): Name of the agent to start

**Example:**
```json
{
  "agent_name": "test-fixer"
}
```

### `supervisor_stop_agent`

Stop a managed agent process.

**Parameters:**
- `agent_name` (string, required): Name of the agent to stop
- `force` (boolean, optional): Force kill the agent (default: false)

**Example:**
```json
{
  "agent_name": "test-fixer",
  "force": true
}
```

### `supervisor_restart_agent`

Restart a managed agent process.

**Parameters:**
- `agent_name` (string, required): Name of the agent to restart

**Example:**
```json
{
  "agent_name": "test-fixer"
}
```

## Agent States

Agents can be in the following states:

- **`:starting`**: Agent is launching
- **`:healthy`**: Agent is running and responding to heartbeats
- **`:degraded`**: Agent is slow to respond (warning state)
- **`:dead`**: Agent is unresponsive (will be restarted per policy)
- **`:stopped`**: Agent was intentionally stopped

## Failure Detection

The supervisor monitors agent health through heartbeats:

1. Agent sends heartbeat every `heartbeat_interval_seconds` (default: 1s)
2. If heartbeat is late, supervisor increments `missed_heartbeats`
3. If `missed_heartbeats >= heartbeat_timeout_count` (default: 5), agent is declared dead
4. Supervisor attempts to force-kill the agent process
5. Supervisor restarts the agent based on its `restart_policy`

## Force Kill Process

When an agent is unresponsive:

1. If PID is known: `kill -9 <pid>`
2. If PID unknown: Find process on port using `lsof -ti:<port>`, then kill
3. Wait 2 seconds for port to be released
4. Execute agent's `repl` script to restart

## Enabling Supervisor Tools

Edit `.mcprepl/tools.json` to enable supervisor tools:

```json
{
  "tool_sets": {
    "supervisor": {
      "enabled": true,
      "description": "Multi-agent process supervision and management",
      "tokens": "~200",
      "tools": [
        "supervisor_status",
        "supervisor_start_agent",
        "supervisor_stop_agent",
        "supervisor_restart_agent"
      ]
    }
  }
}
```

## Example: Multi-Agent Project Structure

```
my-project/
├── .mcprepl/
│   ├── agents.json             # Supervisor & agent configuration
│   └── security.json           # Single-instance security config (optional)
├── .julia-startup.jl           # Shared startup script (auto-detects mode)
├── repl                        # Unified launcher (--supervisor, --agent <name>)
├── agents/
│   ├── test-fixer/
│   │   ├── Project.toml
│   │   └── src/
│   │       └── TestFixer.jl
│   ├── performance-optimizer/
│   │   ├── Project.toml
│   │   └── src/
│   │       └── PerformanceOptimizer.jl
│   └── documentation-writer/
│       ├── Project.toml
│       └── src/
│           └── DocumentationWriter.jl
├── Project.toml                # Supervisor's project
└── src/
    └── MyProject.jl
```

**Key Points:**
- Single shared `.julia-startup.jl` in project root (not per-agent)
- Single `repl` script in project root (handles all modes)
- Agent directories only need `Project.toml` and `src/`

## Troubleshooting

### Agent won't start

Check that:
1. Project root's `repl` script exists and is executable: `chmod +x repl`
2. `.mcprepl/agents.json` exists and contains agent configuration
3. Agent's directory exists and contains `Project.toml`
4. Port is not already in use: `lsof -i :<port>`
5. `jq` is installed (required for JSON parsing): `brew install jq` or `apt-get install jq`

### Agent keeps restarting

Check:
1. Agent logs for errors
2. Heartbeat implementation in agent's startup script
3. Network connectivity to supervisor port
4. Agent's Project.toml has MCPRepl dependency

### Supervisor not detecting failures

Check:
1. Heartbeat interval matches supervisor config
2. Agent is sending heartbeats to correct port
3. Firewall not blocking localhost connections

### Force kill fails

Check:
1. Process actually exists: `lsof -i :<port>`
2. Permissions to kill process
3. Process is not stuck in kernel (D state)

## Best Practices

1. **Set appropriate timeouts**: 5 missed heartbeats = 5 seconds with 1s interval
2. **Rate-limit restarts**: Prevent restart loops with `max_restarts_per_hour`
3. **Use `on_failure` policy**: Only restart when truly needed
4. **Log agent output**: Capture stdout/stderr to files for debugging
5. **Test heartbeat logic**: Ensure agents send heartbeats reliably
6. **Graceful shutdown**: Stop agents cleanly before killing supervisor

## Security Considerations

- Supervisor and each agent have independent security configurations
- Each agent can use different security modes (lax/relaxed/strict)
- Use separate API keys per agent for isolation
- Bind to `127.0.0.1` for local-only access, `0.0.0.0` for network access
- Use IP allowlists in strict mode for network-exposed agents
- Monitor agent logs for suspicious activity
- Limit restart rate to prevent DOS via restart loops

## Future Enhancements

Potential improvements:

- Agent output capture and log management
- Metrics and monitoring dashboard
- Web UI for agent management
- Agent dependency graphs (start order)
- Health check HTTP endpoints
- Agent resource limits (CPU, memory)
- Distributed supervisor (multiple machines)
