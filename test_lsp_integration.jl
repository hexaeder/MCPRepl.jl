#!/usr/bin/env julia
"""
LSP Integration Test Script

This script tests the LSP tools with environment variable authentication
to ensure the VS Code extension properly resolves \${env:MCPREPL_API_KEY}
and communicates back to the MCP server.

Prerequisites:
1. MCP server must be running
2. VS Code Remote Control extension must be installed
3. MCPREPL_API_KEY environment variable must be set (if using auth)
4. VS Code must have a workspace open with this project

Usage:
    julia test_lsp_integration.jl
"""

using MCPRepl
using JSON

println("=" ^ 70)
println("LSP Integration Test - Environment Variable & Port Resolution")
println("=" ^ 70)
println()

# Step 1: Check if server is running
println("📡 Step 1: Checking MCP Server Status")
if MCPRepl.SERVER[] === nothing
    println("   ❌ MCP server is not running!")
    println("   Please start it with: MCPRepl.start!()")
    exit(1)
end
server_port = MCPRepl.SERVER[].port
println("   ✓ MCP server running on port $server_port")
println()

# Step 2: Check extension installation
println("🔌 Step 2: Checking VS Code Extension")
exts_dir = joinpath(homedir(), ".vscode", "extensions")
extension_found = false
if isdir(exts_dir)
    for entry in readdir(exts_dir)
        if startswith(entry, "MCPRepl.vscode-remote-control")
            println("   ✓ Extension found: $entry")
            extension_found = true
            break
        end
    end
end
if !extension_found
    println("   ❌ VS Code Remote Control extension not found!")
    println("   Please run: MCPRepl.setup()")
    exit(1)
end
println()

# Step 3: Check workspace configuration
println("📁 Step 3: Checking Workspace Configuration")
mcp_config_path = joinpath(pwd(), ".vscode", "mcp.json")
security_config_path = joinpath(pwd(), ".mcprepl", "security.json")

has_auth = false
config_port = nothing

if isfile(mcp_config_path)
    println("   ✓ Found .vscode/mcp.json")
    config = JSON.parsefile(mcp_config_path)
    if haskey(config, "servers") && haskey(config["servers"], "julia-repl")
        julia_server = config["servers"]["julia-repl"]
        
        # Check port
        if haskey(julia_server, "url")
            url_match = match(r"localhost:(\d+)", julia_server["url"])
            if url_match !== nothing
                config_port = parse(Int, url_match.captures[1])
                println("   ✓ Config port: $config_port")
            end
        end
        
        # Check auth
        if haskey(julia_server, "headers") && haskey(julia_server["headers"], "Authorization")
            auth_header = julia_server["headers"]["Authorization"]
            println("   ✓ Authorization header: $auth_header")
            
            # Check if using environment variable
            if contains(auth_header, "\${env:")
                env_var_match = match(r"\$\{env:([^}]+)\}", auth_header)
                if env_var_match !== nothing
                    env_var_name = env_var_match.captures[1]
                    env_value = get(ENV, env_var_name, nothing)
                    if env_value !== nothing
                        println("   ✓ Environment variable $env_var_name is set")
                        has_auth = true
                    else
                        println("   ⚠️  Environment variable $env_var_name is NOT set!")
                        println("   Extension will not be able to authenticate")
                    end
                end
            else
                has_auth = true
                println("   ✓ Using literal auth value")
            end
        end
    end
else
    println("   ⚠️  No .vscode/mcp.json found")
end

if isfile(security_config_path)
    println("   ✓ Found .mcprepl/security.json")
    security = JSON.parsefile(security_config_path)
    if haskey(security, "port")
        println("   ✓ Security config port: $(security["port"])")
    end
    if haskey(security, "mode")
        println("   ✓ Security mode: $(security["mode"])")
    end
else
    println("   ⚠️  No .mcprepl/security.json found")
end
println()

# Step 4: Test basic response mechanism
println("🧪 Step 4: Testing Response Storage/Retrieval")
test_id = "test-$(rand(UInt32))"
MCPRepl.store_vscode_response(test_id, "test result", nothing)
try
    result, error = MCPRepl.retrieve_vscode_response(test_id; timeout=1.0)
    if result == "test result" && error === nothing
        println("   ✓ Response storage/retrieval works")
    else
        println("   ❌ Response storage/retrieval failed")
        println("   Expected: 'test result', got: '$result'")
    end
catch e
    println("   ❌ Response mechanism failed: $e")
end
println()

# Step 5: Test VS Code command execution (simple command)
println("🎯 Step 5: Testing VS Code Command Execution")
println("   Attempting to execute 'workbench.action.files.saveAll'...")
println("   (This will save all files in VS Code)")
println()

request_id = string(rand(UInt64), base=16)
uri = MCPRepl.build_vscode_uri(
    "workbench.action.files.saveAll";
    request_id=request_id,
    mcp_port=server_port
)

println("   Generated URI: $uri")
println("   Request ID: $request_id")
println()
println("   Triggering command...")

MCPRepl.trigger_vscode_uri(uri)

println("   Waiting for response (10s timeout)...")
try
    result, error = MCPRepl.retrieve_vscode_response(request_id; timeout=10.0)
    if error === nothing
        println("   ✓ Command executed successfully!")
        println("   Result: $result")
    else
        println("   ❌ Command returned error: $error")
        if contains(string(error), "not allowed")
            println("   💡 Hint: Command may not be in allowedCommands list")
        end
    end
catch e
    println("   ❌ Request timed out or failed: $e")
    println()
    println("   Possible issues:")
    println("   1. VS Code extension not properly installed/activated")
    println("   2. Environment variable not set in VS Code's process")
    println("   3. Port mismatch between config and server")
    println("   4. Authentication failure")
    println()
    println("   Debug steps:")
    println("   - Check VS Code Developer Tools console for errors")
    println("   - Reload VS Code window: Cmd+Shift+P -> 'Reload Window'")
    println("   - Ensure MCPREPL_API_KEY is set in your shell before starting VS Code")
end
println()

# Step 6: Test LSP command (if previous test passed)
println("🔬 Step 6: Testing LSP Command (lsp_workspace_symbols)")
println("   This tests the full LSP integration with environment variable auth")
println()

# Create a simple test file if it doesn't exist
test_file = joinpath(pwd(), "test", "lsp_test_file.jl")
if !isfile(test_file)
    mkpath(dirname(test_file))
    write(test_file, """
    # Test file for LSP integration
    
    function test_function()
        return 42
    end
    
    struct TestType
        value::Int
    end
    """)
    println("   Created test file: $test_file")
end

println("   Calling lsp_workspace_symbols with query 'test'...")
println()

# Get the LSP tool
lsp_tools = MCPRepl.create_lsp_tools()
workspace_symbols_tool = filter(t -> t.id == :lsp_workspace_symbols, lsp_tools)[1]

result = workspace_symbols_tool.handler(Dict("query" => "test"))
println("   Result:")
println("   " * replace(result, "\n" => "\n   "))
println()

if contains(result, "Error") || contains(result, "timed out")
    println("   ❌ LSP command failed!")
    println()
    println("   This confirms the issue. The extension may not be:")
    println("   1. Resolving the environment variable correctly")
    println("   2. Using the correct port")
    println("   3. Sending the response back to the MCP server")
else
    println("   ✓ LSP command succeeded!")
    println("   The environment variable and port resolution are working!")
end
println()

println("=" ^ 70)
println("Test Complete")
println("=" ^ 70)
