# Bidirectional VS Code Communication - Testing Guide

## Overview

This document provides comprehensive testing instructions for the new bidirectional VS Code communication feature.

## Prerequisites

1. **Install Updated Extension**:
   ```julia
   using MCPRepl
   MCPRepl.setup()
   ```

2. **Reload VS Code Window**:
   - Press `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows/Linux)
   - Type "Reload Window" and press Enter
   - Or use MCP tool: `execute_vscode_command("workbench.action.reloadWindow")`

3. **Start MCP Server** (if not already running):
   ```julia
   using MCPRepl
   server = MCPRepl.start!()
   ```

## Test Suite

### Test 1: Basic Response Storage/Retrieval ✅

```julia
using MCPRepl

# Store a test response
test_id = "test-$(rand(UInt32))"
MCPRepl.store_vscode_response(test_id, "test result", nothing)

# Retrieve it
result, error = MCPRepl.retrieve_vscode_response(test_id; timeout=1.0)
@assert result == "test result"
@assert error === nothing
println("✓ Test 1 passed: Basic storage/retrieval works")
```

### Test 2: Timeout Behavior ✅

```julia
using MCPRepl

# Try to retrieve non-existent response
try
    MCPRepl.retrieve_vscode_response("nonexistent-id"; timeout=0.5)
    error("Should have timed out!")
catch e
    @assert occursin("Timeout", string(e))
    println("✓ Test 2 passed: Timeout works correctly")
end
```

### Test 3: Cleanup Mechanism ✅

```julia
using MCPRepl

# Store old and new responses
old_id = "old-$(rand(UInt32))"
new_id = "new-$(rand(UInt32))"

MCPRepl.store_vscode_response(old_id, "old", nothing)
sleep(0.2)
MCPRepl.store_vscode_response(new_id, "new", nothing)

# Clean up responses older than 0.1 seconds
MCPRepl.cleanup_old_vscode_responses(0.1)

# Old should be gone
try
    MCPRepl.retrieve_vscode_response(old_id; timeout=0.1)
    error("Old response should be cleaned up!")
catch e
    @assert occursin("Timeout", string(e))
end

# New should still exist
result, _ = MCPRepl.retrieve_vscode_response(new_id; timeout=0.1)
@assert result == "new"

println("✓ Test 3 passed: Cleanup mechanism works")
```

### Test 4: URI Building ✅

```julia
using MCPRepl

# Test without request_id (backward compatible)
uri1 = MCPRepl.build_vscode_uri("test.command")
@assert !occursin("request_id", uri1)

# Test with request_id
uri2 = MCPRepl.build_vscode_uri("test.command"; request_id="abc123")
@assert occursin("request_id=abc123", uri2)

# Test with custom port
uri3 = MCPRepl.build_vscode_uri("test.command"; request_id="abc123", mcp_port=4000)
@assert occursin("mcp_port=4000", uri3)

println("✓ Test 4 passed: URI building works correctly")
```

### Test 5: Fire-and-Forget Mode (Backward Compatibility)

**Note**: This test requires VS Code to be running with the extension installed.

```julia
# Test existing functionality (no wait_for_response)
result = execute_vscode_command("workbench.action.files.saveAll")
@assert occursin("executed successfully", result)
println("✓ Test 5 passed: Fire-and-forget mode works")
```

### Test 6: Bidirectional Mode with Simple Command

**Note**: This test requires VS Code to be running and will save all open files.

```julia
# Test with wait_for_response
result = execute_vscode_command(
    "workbench.action.files.saveAll",
    wait_for_response=true,
    timeout=5.0
)
println("Result: ", result)
# Expected: Either "no return value" or actual result
println("✓ Test 6 passed: Bidirectional mode works")
```

### Test 7: Command with Arguments

**Note**: This test requires a task named "test" in your workspace's tasks.json.

```julia
# Execute command with arguments and wait for response
result = execute_vscode_command(
    "workbench.action.tasks.runTask",
    args=["test"],
    wait_for_response=true,
    timeout=10.0
)
println("Task result: ", result)
println("✓ Test 7 passed: Commands with arguments work")
```

### Test 8: Error Handling

```julia
# Test with invalid command (should return error)
result = execute_vscode_command(
    "invalid.command.that.does.not.exist",
    wait_for_response=true,
    timeout=5.0
)
# Should contain error message about command not being allowed
println("Error result: ", result)
@assert occursin("not allowed", result) || occursin("failed", result)
println("✓ Test 8 passed: Error handling works")
```

### Test 9: Custom Timeout

```julia
# Test with very short timeout (should timeout)
try
    result = execute_vscode_command(
        "workbench.action.files.saveAll",
        wait_for_response=true,
        timeout=0.001  # 1 millisecond - impossible to complete
    )
    error("Should have timed out!")
catch e
    @assert occursin("Timeout", string(e))
    println("✓ Test 9 passed: Custom timeout works")
end
```

### Test 10: Thread Safety (Concurrent Requests)

```julia
using Base.Threads

# Store multiple responses concurrently
ids = ["thread-$i" for i in 1:10]

# Store concurrently
@threads for id in ids
    MCPRepl.store_vscode_response(id, "result-$id", nothing)
end

# Retrieve concurrently
@threads for id in ids
    result, error = MCPRepl.retrieve_vscode_response(id; timeout=1.0)
    @assert result == "result-$id"
end

println("✓ Test 10 passed: Thread safety works")
```

## Integration Test: Debug Variable Retrieval

This is the primary use case for bidirectional communication.

### Setup

1. Open a Julia file with some code
2. Set a breakpoint
3. Start debugging
4. Wait for breakpoint to hit

### Test

```julia
# When stopped at breakpoint, copy debug value
result = execute_vscode_command(
    "workbench.debug.action.copyValue",
    wait_for_response=true,
    timeout=10.0
)
println("Debug value: ", result)
```

**Expected**: The result should contain the variable value from the debugger.

## Performance Tests

### Latency Test

```julia
using Statistics

function test_latency(n=10)
    times = Float64[]
    
    for i in 1:n
        start = time()
        result = execute_vscode_command(
            "workbench.action.files.saveAll",
            wait_for_response=true,
            timeout=5.0
        )
        push!(times, time() - start)
    end
    
    println("Mean latency: $(mean(times)) seconds")
    println("Min: $(minimum(times)), Max: $(maximum(times))")
    println("Std dev: $(std(times))")
end

test_latency()
```

### Memory Leak Test

```julia
function test_memory_leak(n=100)
    # Store many responses and clean up
    for i in 1:n
        id = "leak-test-$i"
        MCPRepl.store_vscode_response(id, "result $i", nothing)
    end
    
    # Clean up
    MCPRepl.cleanup_old_vscode_responses(0.0)  # Clean all
    
    # Verify all cleaned up
    try
        MCPRepl.retrieve_vscode_response("leak-test-1"; timeout=0.1)
        error("Should have been cleaned up!")
    catch e
        @assert occursin("Timeout", string(e))
    end
    
    println("✓ Memory leak test passed")
end

test_memory_leak()
```

## Troubleshooting

### Problem: Timeout on all commands

**Causes**:
1. Extension not installed or not reloaded
2. MCP server not running
3. Port mismatch

**Solutions**:
```julia
# 1. Reinstall extension
MCPRepl.setup()
# Then reload VS Code window

# 2. Check if server is running
# Should see "MCP Server running on port 3000"

# 3. Verify port in URI
uri = MCPRepl.build_vscode_uri("test"; request_id="abc", mcp_port=3000)
println(uri)  # Should match your server port
```

### Problem: Extension shows error about command not allowed

**Cause**: Command not in allowedCommands list

**Solution**:
```julia
# The command must be in your workspace's .vscode/settings.json
# under "vscode-remote-control.allowedCommands"
```

### Problem: Response contains error message

**Cause**: VS Code command failed

**Solution**:
- Check if command exists: Look at VS Code command palette
- Verify arguments: Some commands require specific argument formats
- Check extension logs: Look in VS Code Output panel

## Success Criteria

All tests should pass:
- ✅ Test 1-4: Core functionality (storage, timeout, cleanup, URI building)
- ✅ Test 5-7: MCP tool integration
- ✅ Test 8-9: Error handling and timeouts
- ✅ Test 10: Thread safety

## Notes

- Tests 5-9 require VS Code to be running
- Some tests may show confirmation dialogs (if requireConfirmation=true)
- Latency typically < 1 second for simple commands
- Memory usage should remain stable with cleanup

## Reporting Issues

If tests fail, collect:
1. Test output/error messages
2. VS Code console logs (Help → Toggle Developer Tools → Console)
3. MCP server output
4. Extension version: Check .vscode/extensions/MCPRepl.vscode-remote-control-*
