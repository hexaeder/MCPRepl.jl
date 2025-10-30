# LSP Tools Troubleshooting Guide

## Problem: LSP tools timeout

If you're experiencing timeouts with LSP tools (`lsp_goto_definition`, `lsp_find_references`, etc.), follow this guide.

## Quick Test

Run the integration test script:
```bash
julia --project=. test_lsp_integration.jl
```

This will check your setup and identify issues.

## Common Issues & Solutions

### 1. Environment Variable Not Set

**Symptom**: Test shows "Environment variable MCPREPL_API_KEY is NOT set!"

**Solution**:
```bash
# Add to ~/.zshrc or ~/.bashrc
export MCPREPL_API_KEY="your-api-key-here"

# Reload shell
source ~/.zshrc

# Verify
echo $MCPREPL_API_KEY

# IMPORTANT: Restart VS Code after setting the env var
# VS Code needs to be started from a shell that has the env var
```

**Verify VS Code has the env var**:
- Open VS Code terminal
- Run: `echo $MCPREPL_API_KEY`
- Should show your API key

### 2. Extension Not Installed or Outdated

**Symptom**: Test shows "VS Code Remote Control extension not found!"

**Solution**:
```julia
using MCPRepl
MCPRepl.setup()  # Follow prompts to install extension
```

Then reload VS Code window:
- `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows/Linux)
- Type "Reload Window" and press Enter

### 3. Port Mismatch

**Symptom**: Extension sends response to wrong port

**Check**:
```julia
# In Julia REPL
MCPRepl.SERVER[].port  # Check actual server port
```

Compare with:
- `.vscode/mcp.json` - should have `"url": "http://localhost:PORT"`
- `.mcprepl/security.json` - should have `"port": PORT`

**Solution**: The fixed extension now reads port from config files automatically.
Reinstall the extension:
```julia
using MCPRepl
MCPRepl.setup()  # Answer yes to reinstall
```

### 4. VS Code Extension Not Resolving Environment Variables

**Symptom**: Authentication fails even though env var is set

**Cause**: Old extension version doesn't resolve `${env:VAR_NAME}` syntax

**Solution**: Update to latest code and reinstall extension:
```bash
cd ~/.julia/dev/MCPRepl
git pull
```

```julia
using MCPRepl
MCPRepl.setup()  # Reinstall extension
```

Reload VS Code window.

### 5. Extension Not Activated

**Symptom**: Commands trigger but no response comes back

**Solution**:
1. Open VS Code Developer Tools: `Help` → `Toggle Developer Tools`
2. Check Console tab for errors
3. Look for "Remote Control" messages
4. If no messages, extension isn't activated

Force activation:
- Trigger any command via `vscode://` URL
- Or reload window

### 6. Security Mode Mismatch

**Symptom**: Server rejects requests with authentication errors

**Check** `.mcprepl/security.json`:
- `:lax` mode → No auth needed (localhost only)
- `:relaxed` mode → API key required
- `:strict` mode → API key + IP allowlist

**Solution**: Ensure your auth configuration matches the security mode.

For `:lax` mode, `.vscode/mcp.json` should NOT have Authorization header.

## Manual Testing Steps

### Test 1: Basic Response Mechanism
```julia
using MCPRepl

# Store a test response
test_id = "manual-test-$(rand(UInt32))"
MCPRepl.store_vscode_response(test_id, "hello", nothing)

# Retrieve it
result, error = MCPRepl.retrieve_vscode_response(test_id; timeout=1.0)
@assert result == "hello"
println("✓ Basic mechanism works")
```

### Test 2: VS Code Command with Response
```julia
using MCPRepl

# Execute a simple command
request_id = string(rand(UInt64), base=16)
uri = MCPRepl.build_vscode_uri(
    "workbench.action.files.saveAll";
    request_id=request_id,
    mcp_port=MCPRepl.SERVER[].port
)

MCPRepl.trigger_vscode_uri(uri)

# Wait for response
result, error = MCPRepl.retrieve_vscode_response(request_id; timeout=5.0)
println("Result: ", result)
println("Error: ", error)
```

### Test 3: LSP Command
```julia
using MCPRepl

tools = MCPRepl.create_lsp_tools()
ws_symbols = filter(t -> t.id == :lsp_workspace_symbols, tools)[1]

# Search for symbols
result = ws_symbols.handler(Dict("query" => "function"))
println(result)
```

## Checking Extension Logs

1. Open VS Code Developer Tools (`Help` → `Toggle Developer Tools`)
2. Go to Console tab
3. Filter for "Remote Control" or "MCP"
4. Look for:
   - Environment variable resolution messages
   - Port detection messages
   - HTTP request errors
   - Authentication errors

## Verifying Extension Code

Check the installed extension has the fixes:
```bash
cat ~/.vscode/extensions/MCPRepl.vscode-remote-control-*/out/extension.js | grep "envVarMatch"
```

Should show code that resolves `${env:VAR_NAME}`.

## Still Not Working?

1. **Capture extension logs**:
   - Open VS Code Developer Tools
   - Reproduce the issue
   - Copy console output

2. **Check server logs**:
   ```julia
   # In Julia REPL where server is running
   # Watch for incoming requests
   ```

3. **Verify network**:
   ```bash
   # Check server is listening
   lsof -i :3000  # Replace 3000 with your port
   
   # Test server endpoint
   curl -X POST http://localhost:3000/vscode-response \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer YOUR_API_KEY" \
     -d '{"request_id": "test", "result": "hello"}'
   ```

4. **Create a minimal reproduction**:
   - Fresh Julia session
   - Start MCP server
   - Run test script
   - Share output

## Expected Behavior

When everything works correctly:

1. LSP command triggers
2. VS Code extension receives URI
3. Extension reads config files for port and auth
4. Extension resolves `${env:MCPREPL_API_KEY}`
5. Extension executes LSP command
6. Extension POSTs result to `http://localhost:PORT/vscode-response`
7. MCP server stores response
8. Julia code retrieves response
9. Result returned to caller

Total time: < 1 second for simple commands, < 5 seconds for LSP commands.
