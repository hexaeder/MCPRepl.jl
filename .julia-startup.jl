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
                port = parse(Int, get(ENV, "JULIA_MCP_PORT", "3000"))
                MCPRepl.start!(; port = port, verbose = false)

                # Wait a moment for server to fully initialize
                sleep(0.5)

                # Test server connectivity
                test_result = MCPRepl.test_server(port)

                if test_result
                    @info "✓ MCP REPL server started and responding on port $port"
                else
                    @info "✓ MCP REPL server started on port $port"
                end
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
                @warn "Could not start MCP REPL server" exception = e
            end
        end
    end
catch e
    @warn "Could not start MCP REPL server" exception = e
end
