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

Create an `agents.json` file in your project root:

```json
{
  "supervisor": {
    "heartbeat_interval_seconds": 1,
    "heartbeat_timeout_count": 5,
    "max_restarts_per_hour": 10
  },
  "agents": {
    "test-fixer": {
      "port": 3001,
      "directory": "agents/test-fixer",
      "description": "Analyzes and fixes test failures",
      "auto_start": true,
      "restart_policy": "always"
    },
    "performance-optimizer": {
      "port": 3002,
      "directory": "agents/performance-optimizer",
      "description": "Profiles code and optimizes performance",
      "auto_start": true,
      "restart_policy": "on_failure"
    }
  }
}
```

### 2. Create Agent Directories

Each agent needs its own directory with a `repl` launcher script:

```bash
mkdir -p agents/test-fixer
mkdir -p agents/performance-optimizer
```

Create `agents/test-fixer/repl`:

```bash
#!/usr/bin/env bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"
exec julia --project=. --load=.julia-startup.jl "$@"
```

Make it executable:
```bash
chmod +x agents/test-fixer/repl
```

Create a `.julia-startup.jl` in each agent directory that:
1. Activates the agent's environment
2. Starts MCPRepl on the agent's port
3. Sends heartbeats to the supervisor

### 3. Start Supervisor

Start MCPRepl with supervisor mode enabled:

```julia
using MCPRepl
MCPRepl.start!(supervisor=true, agents_config="agents.json")
```

The supervisor will:
- Load agent configurations
- Start the supervisor monitor loop
- Auto-start agents with `auto_start: true`
- Monitor heartbeats and restart failed agents

## Agent Configuration

### Supervisor Settings

```json
{
  "supervisor": {
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
    "port": 3001,                       // Port for agent's MCP server
    "directory": "agents/agent-name",   // Agent's working directory
    "description": "What this agent does",
    "auto_start": true,                 // Start automatically with supervisor
    "restart_policy": "always"          // "always", "on_failure", or "never"
  }
}
```

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
    "port": 3001,
    "status": "healthy",
    "timestamp": "2025-11-02T18:48:00Z"
  }
}
```

Example agent startup code:

```julia
using MCPRepl
using HTTP
using JSON

# Start this agent's MCP server
MCPRepl.start!(port=3001)

# Send heartbeats to supervisor
@async begin
    supervisor_url = "http://localhost:3000/"

    while true
        try
            heartbeat = Dict(
                "jsonrpc" => "2.0",
                "method" => "supervisor/heartbeat",
                "id" => 1,
                "params" => Dict(
                    "agent_name" => "test-fixer",
                    "pid" => getpid(),
                    "port" => 3001,
                    "status" => "healthy",
                    "timestamp" => string(now())
                )
            )

            HTTP.post(
                supervisor_url,
                ["Content-Type" => "application/json"],
                JSON.json(heartbeat)
            )
        catch e
            @warn "Failed to send heartbeat" exception=e
        end

        sleep(1)  # Match heartbeat_interval_seconds
    end
end
```

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
├── agents.json                 # Supervisor configuration
├── agents/
│   ├── test-fixer/
│   │   ├── repl                # Launcher script
│   │   ├── .julia-startup.jl   # Startup with heartbeats
│   │   ├── Project.toml
│   │   └── src/
│   │       └── TestFixer.jl
│   ├── performance-optimizer/
│   │   ├── repl
│   │   ├── .julia-startup.jl
│   │   ├── Project.toml
│   │   └── src/
│   │       └── PerformanceOptimizer.jl
│   └── documentation-writer/
│       ├── repl
│       ├── .julia-startup.jl
│       ├── Project.toml
│       └── src/
│           └── DocumentationWriter.jl
├── Project.toml
└── src/
    └── MyProject.jl
```

## Troubleshooting

### Agent won't start

Check that:
1. Agent's `repl` script exists and is executable
2. Agent's directory contains `.julia-startup.jl`
3. Port is not already in use: `lsof -i :<port>`

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

- Supervisor runs with same privileges as main Julia process
- Agents inherit security configuration from supervisor
- Use separate API keys per agent for strict security
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
