using MCPRepl

# Start the proxy server
server = MCPRepl.Proxy.start_server(3000)

# Keep the server running
println("Proxy server running. Press Ctrl+C to stop.")
wait()
