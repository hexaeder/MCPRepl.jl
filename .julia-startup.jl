using Pkg
Pkg.activate(".")
import Base.Threads

# If running as agent, ensure MCPRepl is synced from supervisor environment
agent_name = get(ENV, "JULIA_MCP_AGENT_NAME", "")
if !isempty(agent_name)
    # Check if MCPRepl is in this agent's environment
    agent_deps = Pkg.project().dependencies

    if !haskey(agent_deps, "MCPRepl")
        @info "Agent '$agent_name': Syncing MCPRepl from supervisor environment..."

        # Find supervisor project (parent directory)
        supervisor_project_path = joinpath(dirname(pwd()), "Project.toml")

        if isfile(supervisor_project_path)
            using TOML
            supervisor_project = TOML.parsefile(supervisor_project_path)

            # Check if supervisor is using dev version
            supervisor_manifest_path = joinpath(dirname(pwd()), "Manifest.toml")
            if isfile(supervisor_manifest_path)
                supervisor_manifest = TOML.parsefile(supervisor_manifest_path)

                # Look for MCPRepl in manifest
                if haskey(supervisor_manifest, "deps") && haskey(supervisor_manifest["deps"], "MCPRepl")
                    mcprepl_info = supervisor_manifest["deps"]["MCPRepl"]

                    # Check if it's a dev dependency (has path)
                    if haskey(mcprepl_info, "path")
                        # Dev version - use the same path
                        dev_path = joinpath(dirname(pwd()), mcprepl_info["path"])
                        @info "  Using dev version from: $dev_path"
                        Pkg.develop(path=dev_path)
                    else
                        # Registered version - add it (will sync via Manifest)
                        @info "  Adding MCPRepl package"
                        Pkg.add("MCPRepl")
                    end
                else
                    # Fallback: just add MCPRepl
                    @info "  Adding MCPRepl package"
                    Pkg.add("MCPRepl")
                end
            else
                # No manifest, just add it
                @info "  Adding MCPRepl package"
                Pkg.add("MCPRepl")
            end

            # Instantiate to ensure all dependencies are ready
            Pkg.instantiate()
        else
            @warn "Could not find supervisor Project.toml at $supervisor_project_path"
            @info "  Adding MCPRepl package anyway"
            Pkg.add("MCPRepl")
            Pkg.instantiate()
        end
    end
end

# Load Revise for hot reloading (optional but recommended)
try
    using Revise
    @info "✓ Revise loaded - code changes will be tracked and auto-reloaded"
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\"Revise\"))"
end
using MCPRepl

# Start MCP REPL server for AI agent integration
try
    if Threads.threadid() == 1
        Threads.@spawn begin
            try
                sleep(1)

                # Check if supervisor mode is enabled via environment variable
                supervisor_enabled = get(ENV, "JULIA_MCP_SUPERVISOR", "false") == "true"

                # Port is determined by:
                # 1. JULIA_MCP_PORT environment variable (highest priority)
                # 2. .mcprepl/security.json port field (default)
                #
                # Heartbeats are automatically started by MCPRepl.start!() if
                # JULIA_MCP_AGENT_NAME environment variable is set
                MCPRepl.start!(verbose=false, supervisor=supervisor_enabled)

                # Wait a moment for server to fully initialize
                sleep(0.5)

                @info "✓ MCP REPL server started 🐉"

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
