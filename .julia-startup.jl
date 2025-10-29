using Pkg
Pkg.activate(".")
import Base.Threads
using MCPRepl

# Load Revise for hot reloading (optional but recommended)
try
    using Revise
    @info "✓ Revise loaded - code changes will be tracked and auto-reloaded"
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\"Revise\"))"
end

# Start MCP REPL server for VS Code Copilot integration
try
    if Threads.threadid() == 1
        Threads.@spawn begin
            try
                sleep(1)
                # Port is determined by:
                # 1. JULIA_MCP_PORT environment variable (highest priority)
                # 2. .mcprepl/security.json port field (default)
                MCPRepl.start!(verbose=false)

                # Wait a moment for server to fully initialize
                sleep(0.5)

                @info "✓ MCP REPL server started 🐉"
                # Refresh the prompt to ensure clean display after test completes
                if isdefined(Base, :active_repl)
                    try
                        println()  # Add clean newline
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
