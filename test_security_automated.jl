#!/usr/bin/env julia
# Automated test of security system

using Pkg
Pkg.activate(".")

# Clean slate
config_dir = joinpath(pwd(), ".mcprepl")
if isdir(config_dir)
    rm(config_dir; recursive = true, force = true)
end

using MCPRepl

println("╔════════════════════════════════════════════════════════╗")
println("║  Testing MCPRepl Security System                       ║")
println("╚════════════════════════════════════════════════════════╝")
println()

# Test 1: Quick setup with different modes
println("📝 Test 1: Quick setup with :lax mode")
config = MCPRepl.quick_setup(:lax)
println("✅ Config created: mode=$(config.mode), keys=$(length(config.api_keys))")
println()

# Test 2: Load and verify
println("📝 Test 2: Load existing config")
loaded = MCPRepl.load_security_config()
@assert loaded !== nothing "Failed to load config"
@assert loaded.mode == :lax "Mode mismatch"
println("✅ Config loaded successfully")
println()

# Test 3: Change mode to strict
println("📝 Test 3: Change to strict mode")
MCPRepl.set_security_mode(:strict)
loaded = MCPRepl.load_security_config()
@assert loaded.mode == :strict "Mode change failed"
println("✅ Mode changed to :strict")
println()

# Test 4: Generate API key
println("📝 Test 4: Generate API key")
key = MCPRepl.generate_key()
@assert startswith(key, "mcprepl_") "Invalid key format"
@assert length(key) == 48 "Invalid key length"  # "mcprepl_" (8) + 40 hex chars
println("✅ API key generated: $(key[1:15])...$(key[end-3:end])")
println()

# Test 5: Add/remove IP
println("📝 Test 5: IP allowlist management")
MCPRepl.allow_ip("192.168.1.100")
loaded = MCPRepl.load_security_config()
@assert "192.168.1.100" in loaded.allowed_ips "IP not added"
println("✅ IP added to allowlist")

MCPRepl.deny_ip("192.168.1.100")
loaded = MCPRepl.load_security_config()
@assert !("192.168.1.100" in loaded.allowed_ips) "IP not removed"
println("✅ IP removed from allowlist")
println()

# Test 6: Security status display
println("📝 Test 6: Display security status")
MCPRepl.security_status()
println()

println("╔════════════════════════════════════════════════════════╗")
println("║  ✅ All security tests passed!                         ║")
println("╚════════════════════════════════════════════════════════╝")
