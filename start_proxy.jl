# Simple script to start just the proxy server
# The Proxy module is internal to MCPRepl, so we activate the environment and include it directly

using Pkg
Pkg.activate(@__DIR__)

# Include and use the Proxy module
include("src/dashboard.jl")
include("src/proxy.jl")
using .Proxy

# Start the proxy in foreground mode
server = Proxy.start_foreground_server(3000)

# Keep the server running
println("Proxy server running on port 3000. Press Ctrl+C to stop.")
wait(server)
