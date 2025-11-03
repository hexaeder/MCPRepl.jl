using Pkg
Pkg.activate(".")
import Base.Threads

# Load Revise for hot reloading (optional but recommended)
try
    using Revise
    @info "✓ Revise loaded - code changes will be tracked and auto-reloaded"
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\"Revise\"))"
end
using MCPRepl
using HTTP
using JSON

# Start MCP REPL server for AI agent integration
try
    if Threads.threadid() == 1
        Threads.@spawn begin
            try
                sleep(1)

                # Check if supervisor mode is enabled via environment variable
                supervisor_enabled = get(ENV, "JULIA_MCP_SUPERVISOR", "false") == "true"

                # Check if running as an agent
                agent_name = get(ENV, "JULIA_MCP_AGENT_NAME", "")
                is_agent_mode = !isempty(agent_name)

                # Port is determined by:
                # 1. JULIA_MCP_PORT environment variable (highest priority)
                # 2. .mcprepl/security.json port field (default)
                MCPRepl.start!(verbose=false, supervisor=supervisor_enabled)

                # Wait a moment for server to fully initialize
                sleep(0.5)

                @info "✓ MCP REPL server started 🐉"

                # Start heartbeat loop if in agent mode
                if is_agent_mode
                    @info "Agent mode: sending heartbeats as '$agent_name'"

                    # Read supervisor configuration
                    config_path = joinpath(dirname(dirname(pwd())), "agents.json")
                    supervisor_port = 3000  # Default

                    if isfile(config_path)
                        try
                            config = JSON.parsefile(config_path)
                            supervisor_port = get(get(config, "supervisor", Dict()), "port", 3000)
                        catch e
                            @warn "Could not read supervisor config" exception=e
                        end
                    end

                    supervisor_url = "http://localhost:\$supervisor_port/"

                    # Start heartbeat task
                    Threads.@spawn begin
                        while true
                            try
                                heartbeat = Dict(
                                    "jsonrpc" => "2.0",
                                    "method" => "supervisor/heartbeat",
                                    "id" => 1,
                                    "params" => Dict(
                                        "agent_name" => agent_name,
                                        "pid" => getpid(),
                                        "status" => "healthy",
                                        "timestamp" => string(Dates.now())
                                    )
                                )

                                HTTP.post(
                                    supervisor_url,
                                    ["Content-Type" => "application/json"],
                                    JSON.json(heartbeat);
                                    readtimeout=2,
                                    connect_timeout=1
                                )
                            catch e
                                # Silently ignore heartbeat failures (supervisor may not be running yet)
                            end

                            sleep(1)  # Send heartbeat every second
                        end
                    end
                end

                # Refresh the prompt to ensure clean display after test completes
                if isdefined(Base, :active_repl)
                    try
                        println();println()  # Add clean newline
                        REPL.LineEdit.refresh_line(Base.active_repl.mistate)
                    catch
                        # Ignore if REPL isn't ready yet
                    end
                end
            catch e
                @warn "Could not start MCP REPL server" exception=e
            end
        end
    end
catch e
    @warn "Could not start MCP REPL server" exception=e
end
