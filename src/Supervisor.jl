# ============================================================================
# Supervisor Module - Multi-Agent REPL Process Management
# ============================================================================

"""
    Supervisor

Module for managing multiple Julia REPL agent processes.

Provides process supervision with:
- Heartbeat monitoring
- Automatic restarts on failure
- Force-kill of zombie processes
- Agent lifecycle management
- Status reporting

The supervisor runs in a background thread and monitors agent heartbeats.
If an agent misses too many heartbeats, it's considered dead and will be
automatically restarted.
"""
module Supervisor

using Dates
using JSON

export AgentState, AgentRegistry
export start_supervisor, stop_supervisor
export load_agents_config

# ============================================================================
# Agent State Tracking
# ============================================================================

"""
Agent status states:
- :starting - Agent is launching
- :healthy - Agent is running and responding
- :degraded - Agent is slow to respond
- :dead - Agent is unresponsive
- :stopped - Agent was intentionally stopped
"""
const AgentStatus = Symbol

mutable struct AgentState
    name::String
    port::Int
    pid::Union{Int,Nothing}
    directory::String
    description::String
    status::AgentStatus
    last_heartbeat::DateTime
    missed_heartbeats::Int
    restarts::Int
    uptime_start::Union{DateTime,Nothing}
    auto_start::Bool
    restart_policy::String  # "always", "on_failure", "never"
end

function AgentState(name::String, port::Int, directory::String, description::String;
                    auto_start::Bool=true, restart_policy::String="on_failure")
    AgentState(
        name,
        port,
        nothing,  # pid unknown initially
        directory,
        description,
        :starting,
        now(),
        0,
        0,
        nothing,
        auto_start,
        restart_policy
    )
end

"""
Get human-readable uptime string for an agent.
"""
function uptime_string(state::AgentState)::String
    if state.uptime_start === nothing
        return "not started"
    end

    duration = now() - state.uptime_start
    hours = div(duration, Hour(1))
    mins = div(duration - Hour(hours), Minute(1))

    if hours > 0
        return "$(hours)h $(mins)m"
    else
        return "$(mins)m"
    end
end

"""
Get time since last heartbeat as a human-readable string.
"""
function heartbeat_age_string(state::AgentState)::String
    age = now() - state.last_heartbeat
    secs = div(age, Second(1))

    if secs < 60
        return "$(secs)s ago"
    elseif secs < 3600
        return "$(div(secs, 60))m ago"
    else
        return "$(div(secs, 3600))h ago"
    end
end

# ============================================================================
# Agent Registry
# ============================================================================

"""
Thread-safe registry of all managed agents.
"""
mutable struct AgentRegistry
    agents::Dict{String,AgentState}
    lock::ReentrantLock
    monitor_task::Union{Task,Nothing}
    running::Bool

    # Configuration
    heartbeat_interval::Int  # seconds
    heartbeat_timeout_count::Int
    max_restarts_per_hour::Int
end

function AgentRegistry(;
                       heartbeat_interval::Int=1,
                       heartbeat_timeout_count::Int=5,
                       max_restarts_per_hour::Int=10)
    AgentRegistry(
        Dict{String,AgentState}(),
        ReentrantLock(),
        nothing,
        false,
        heartbeat_interval,
        heartbeat_timeout_count,
        max_restarts_per_hour
    )
end

"""
    register_agent!(registry::AgentRegistry, agent::AgentState)

Register a new agent with the supervisor.
"""
function register_agent!(registry::AgentRegistry, agent::AgentState)
    lock(registry.lock) do
        registry.agents[agent.name] = agent
    end
end

"""
    get_agent(registry::AgentRegistry, name::String)

Get agent state by name (thread-safe).
"""
function get_agent(registry::AgentRegistry, name::String)::Union{AgentState,Nothing}
    lock(registry.lock) do
        get(registry.agents, name, nothing)
    end
end

"""
    update_heartbeat!(registry::AgentRegistry, name::String, pid::Int)

Update the heartbeat timestamp for an agent.
"""
function update_heartbeat!(registry::AgentRegistry, name::String, pid::Int)
    lock(registry.lock) do
        agent = get(registry.agents, name, nothing)
        if agent !== nothing
            agent.last_heartbeat = now()
            agent.missed_heartbeats = 0
            agent.pid = pid

            # Update status
            if agent.status == :starting || agent.status == :dead
                agent.status = :healthy
                if agent.uptime_start === nothing
                    agent.uptime_start = now()
                end
            end
        end
    end
end

"""
    get_all_agents(registry::AgentRegistry)

Get a copy of all agent states (thread-safe).
"""
function get_all_agents(registry::AgentRegistry)::Dict{String,AgentState}
    lock(registry.lock) do
        copy(registry.agents)
    end
end

# ============================================================================
# Process Management
# ============================================================================

"""
    kill_process_on_port(port::Int)

Find and forcefully kill a process bound to the given port using lsof.
Returns the PID that was killed, or nothing if no process found.
"""
function kill_process_on_port(port::Int)::Union{Int,Nothing}
    try
        # Use lsof to find process on port
        output = read(`lsof -ti:$port`, String)
        pid = parse(Int, strip(output))

        @warn "Killing process on port $port" pid=pid
        run(`kill -9 $pid`)

        # Wait for port to be released
        sleep(2)

        return pid
    catch e
        @debug "Could not find/kill process on port $port" exception=e
        return nothing
    end
end

"""
    force_kill_agent(agent::AgentState)

Force kill an agent by PID or by finding it on its configured port.
"""
function force_kill_agent(agent::AgentState)::Bool
    if agent.pid !== nothing
        try
            @warn "Force killing agent" name=agent.name pid=agent.pid
            run(`kill -9 $(agent.pid)`)
            sleep(2)
            return true
        catch e
            @warn "Failed to kill agent by PID, trying port" name=agent.name exception=e
        end
    end

    # Fall back to killing by port
    pid = kill_process_on_port(agent.port)
    return pid !== nothing
end

"""
    start_agent(agent::AgentState)

Start an agent by executing the project root's repl script with --agent flag.
"""
function start_agent(agent::AgentState)::Bool
    # Use project root's repl script with --agent <name>
    repl_script = "./repl"

    if !isfile(repl_script)
        @error "Project repl script not found" name=agent.name path=repl_script
        return false
    end

    # Make sure script is executable
    try
        chmod(repl_script, 0o755)
    catch
        # Ignore chmod errors on Windows
    end

    @info "Starting agent" name=agent.name directory=agent.directory port=agent.port

    try
        # Launch in detached mode so it survives even if supervisor dies
        # Use --agent <name> to specify which agent to start
        run(detach(`$repl_script --agent $(agent.name)`))

        agent.status = :starting
        agent.uptime_start = now()

        return true
    catch e
        @error "Failed to start agent" name=agent.name exception=e
        agent.status = :dead
        return false
    end
end

"""
    restart_agent(agent::AgentState)

Restart an agent (kill if running, then start).
"""
function restart_agent(agent::AgentState)::Bool
    @info "Restarting agent" name=agent.name restarts=agent.restarts

    # Force kill if running
    if agent.status != :stopped
        force_kill_agent(agent)
    end

    # Increment restart counter
    agent.restarts += 1

    # Start agent
    return start_agent(agent)
end

"""
    stop_agent(agent::AgentState; force::Bool=false)

Stop an agent gracefully (or forcefully if force=true).
"""
function stop_agent(agent::AgentState; force::Bool=false)::Bool
    if force
        @info "Force stopping agent" name=agent.name
        success = force_kill_agent(agent)
    else
        # Try graceful shutdown first (send SIGTERM)
        if agent.pid !== nothing
            try
                @info "Gracefully stopping agent" name=agent.name pid=agent.pid
                run(`kill -15 $(agent.pid)`)
                sleep(2)
                success = true
            catch e
                @warn "Graceful shutdown failed, using force" name=agent.name exception=e
                success = force_kill_agent(agent)
            end
        else
            # No PID known, use force
            success = force_kill_agent(agent)
        end
    end

    if success
        agent.status = :stopped
        agent.pid = nothing
        agent.uptime_start = nothing
    end

    return success
end

# ============================================================================
# Supervisor Monitor Loop
# ============================================================================

"""
    supervisor_monitor_loop(registry::AgentRegistry)

Background thread that monitors agent heartbeats and restarts failed agents.
"""
function supervisor_monitor_loop(registry::AgentRegistry)
    @info "Supervisor monitor loop starting"

    while registry.running
        try
            sleep(registry.heartbeat_interval)

            # Check all agents
            agents = get_all_agents(registry)

            for (name, agent) in agents
                # Skip if agent is intentionally stopped
                if agent.status == :stopped
                    continue
                end

                # Calculate heartbeat age
                age = now() - agent.last_heartbeat
                age_seconds = div(age, Second(1))

                # Check if heartbeat is late
                if age_seconds > registry.heartbeat_interval
                    lock(registry.lock) do
                        agent.missed_heartbeats += 1

                        # Update status based on missed heartbeats
                        if agent.missed_heartbeats >= registry.heartbeat_timeout_count
                            @warn "Agent is dead (missed heartbeats)" name=name missed=agent.missed_heartbeats
                            agent.status = :dead

                            # Attempt restart based on policy
                            if should_restart(agent, registry)
                                restart_agent(agent)
                            else
                                @warn "Not restarting agent (policy or restart limit)" name=name policy=agent.restart_policy restarts=agent.restarts
                            end
                        elseif agent.missed_heartbeats >= div(registry.heartbeat_timeout_count, 2)
                            # Agent is degraded (slow to respond)
                            if agent.status == :healthy
                                @warn "Agent is degraded" name=name missed=agent.missed_heartbeats
                                agent.status = :degraded
                            end
                        end
                    end
                end
            end
        catch e
            @error "Error in supervisor monitor loop" exception=e
        end
    end

    @info "Supervisor monitor loop stopped"
end

"""
    should_restart(agent::AgentState, registry::AgentRegistry)

Determine if an agent should be restarted based on its policy and restart history.
"""
function should_restart(agent::AgentState, registry::AgentRegistry)::Bool
    # Check restart policy
    if agent.restart_policy == "never"
        return false
    end

    if agent.restart_policy == "on_failure" && agent.status != :dead
        return false
    end

    # Check restart rate limit
    # TODO: Track restart timestamps and enforce max_restarts_per_hour
    # For now, just check total restarts
    if agent.restarts >= registry.max_restarts_per_hour
        @warn "Agent has reached max restarts limit" name=agent.name restarts=agent.restarts limit=registry.max_restarts_per_hour
        return false
    end

    return true
end

# ============================================================================
# Supervisor Lifecycle
# ============================================================================

"""
    start_supervisor(registry::AgentRegistry)

Start the supervisor monitor loop in a background thread.
"""
function start_supervisor(registry::AgentRegistry)
    if registry.running
        @warn "Supervisor already running"
        return
    end

    registry.running = true

    # Start monitor loop in background thread
    registry.monitor_task = @async supervisor_monitor_loop(registry)

    @info "Supervisor started"
end

"""
    stop_supervisor(registry::AgentRegistry; stop_agents::Bool=true)

Stop the supervisor monitor loop and optionally stop all agents.
"""
function stop_supervisor(registry::AgentRegistry; stop_agents::Bool=true)
    if !registry.running
        @warn "Supervisor not running"
        return
    end

    @info "Stopping supervisor" stop_agents=stop_agents

    registry.running = false

    # Wait for monitor loop to finish
    if registry.monitor_task !== nothing
        try
            wait(registry.monitor_task)
        catch
            # Ignore errors during shutdown
        end
    end

    # Stop all agents if requested
    if stop_agents
        agents = get_all_agents(registry)
        for (name, agent) in agents
            if agent.status != :stopped
                stop_agent(agent; force=true)
            end
        end
    end

    @info "Supervisor stopped"
end

# ============================================================================
# Configuration Loading
# ============================================================================

"""
    load_agents_config(path::String=".mcprepl/agents.json")

Load agents configuration from JSON file.

Example agents.json:
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
    }
  }
}
```
"""
function load_agents_config(path::String=".mcprepl/agents.json")::Union{AgentRegistry,Nothing}
    if !isfile(path)
        @warn "Agents config file not found" path=path
        return nothing
    end

    try
        config = JSON.parsefile(path)

        # Parse supervisor settings
        supervisor_config = get(config, "supervisor", Dict())
        heartbeat_interval = get(supervisor_config, "heartbeat_interval_seconds", 1)
        heartbeat_timeout_count = get(supervisor_config, "heartbeat_timeout_count", 5)
        max_restarts_per_hour = get(supervisor_config, "max_restarts_per_hour", 10)

        # Create registry
        registry = AgentRegistry(
            heartbeat_interval=heartbeat_interval,
            heartbeat_timeout_count=heartbeat_timeout_count,
            max_restarts_per_hour=max_restarts_per_hour
        )

        # Parse agents
        agents = get(config, "agents", Dict())
        for (name, agent_config) in agents
            port = agent_config["port"]
            directory = agent_config["directory"]
            description = get(agent_config, "description", "")
            auto_start = get(agent_config, "auto_start", true)
            restart_policy = get(agent_config, "restart_policy", "on_failure")

            agent = AgentState(
                name, port, directory, description;
                auto_start=auto_start, restart_policy=restart_policy
            )

            register_agent!(registry, agent)
        end

        @info "Loaded agents configuration" path=path agent_count=length(registry.agents)

        return registry
    catch e
        @error "Failed to load agents config" path=path exception=e
        return nothing
    end
end

end # module Supervisor
