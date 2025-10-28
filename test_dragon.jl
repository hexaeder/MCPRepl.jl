#!/usr/bin/env julia
# Quick test to see the dragon wizard in action

using Pkg
Pkg.activate(".")

# Remove any existing security config for a fresh demo
config_dir = joinpath(pwd(), ".mcprepl")
if isdir(config_dir)
    rm(config_dir; recursive=true, force=true)
    println("Removed existing config for fresh demo")
end

using MCPRepl

# This should trigger the dragon wizard since there's no config
println("\n=== Calling setup_security() ===\n")
MCPRepl.setup_security()
