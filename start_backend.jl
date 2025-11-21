using MCPRepl

# Start backend REPL on port 3006
# The start! function automatically detects and connects to the proxy on port 3000
MCPRepl.start!(port=3006)

# Keep running
println("Backend REPL running on port 3006. Press Ctrl+C to stop.")
wait()
