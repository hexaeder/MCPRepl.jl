using MCPRepl

# This should auto-start proxy if needed, then start backend REPL
MCPRepl.start!(port=3006)

# Keep running
println("MCPRepl started. Press Ctrl+C to stop.")
wait()
