# Bidirectional VS Code Communication - IMPLEMENTATION COMPLETE ✅

## Status: ✅ COMPLETED

All phases implemented and tested. The MCP server now supports bidirectional communication with VS Code.

## What Was Implemented

### Phase 1: VS Code Extension Enhancement ✅
**File**: `src/vscode.jl` (extension.js generation)

**Changes**:
- Added `request_id` and `mcp_port` query parameter support
- Extension now captures `executeCommand()` return values
- Implemented `sendResponse()` helper function using Node.js `http` module
- POST responses back to `http://localhost:3000/vscode-response` (or custom port)
- Error handling for all failure scenarios

**Technical Details**:
- Uses native Node.js `http.request()` (no external dependencies)
- Sends JSON payload: `{request_id, result, error, timestamp}`
- Only sends response if `request_id` is provided (backward compatible)

### Phase 2: Response Storage Mechanism ✅
**File**: `src/MCPRepl.jl`

**Added Functions**:
1. `store_vscode_response(request_id, result, error)` - Thread-safe storage
2. `retrieve_vscode_response(request_id; timeout, poll_interval)` - Polling retrieval with timeout
3. `cleanup_old_vscode_responses(max_age)` - Prevent memory leaks

**Technical Details**:
- Global `VSCODE_RESPONSES` Dict with ReentrantLock for thread safety
- Stores tuple: `(result, error, timestamp)`
- Auto-cleanup on retrieval
- Configurable timeout (default: 5 seconds)
- Polling interval: 0.1 seconds

### Phase 3: MCP Server Endpoint ✅
**File**: `src/MCPServer.jl`

**Added Endpoint**: `POST /vscode-response`
- Accepts JSON: `{request_id, result, error, timestamp}`
- Validates `request_id` presence
- Stores response using `MCPRepl.store_vscode_response()`
- Returns 200 OK or appropriate error response

**Technical Details**:
- Inserted before OAuth handlers to avoid JSON parsing conflicts
- Proper error handling with 400/500 status codes
- Thread-safe via MCPRepl's locking mechanism

### Phase 4: Enhanced execute_vscode_command Tool ✅
**File**: `src/MCPRepl.jl` (vscode_command_tool)

**New Parameters**:
- `wait_for_response: boolean` (default: false) - Enable bidirectional mode
- `timeout: number` (default: 5.0) - Response timeout in seconds

**Behavior**:
- When `wait_for_response=false`: Fire-and-forget (backward compatible)
- When `wait_for_response=true`:
  1. Generates unique request_id (128-bit random hex)
  2. Includes request_id in URI
  3. Waits for response with timeout
  4. Returns formatted result or error message

**Output Format**:
- Success: `"VS Code command 'X' result:\n<pretty JSON>"`
- Error: `"VS Code command 'X' failed: <error>"`
- Timeout: `"Error waiting for VS Code response: Timeout..."`

## Testing Results ✅

All tests passed:
1. ✅ Response storage/retrieval
2. ✅ Timeout behavior
3. ✅ Cleanup mechanism
4. ✅ URI building with request_id
5. ✅ Custom port support
6. ✅ Thread safety

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Bidirectional Flow                        │
└─────────────────────────────────────────────────────────────┘

1. Julia MCP Tool (execute_vscode_command)
   ├─ Generates request_id if wait_for_response=true
   ├─ Builds URI: vscode://...?cmd=X&request_id=Y&mcp_port=3000
   └─ Opens URI → triggers VS Code

2. VS Code Extension (URI Handler)
   ├─ Parses request_id and mcp_port from URI
   ├─ Executes command: result = await executeCommand(cmd, ...args)
   └─ POSTs to http://localhost:{mcp_port}/vscode-response
      Body: {request_id, result, error, timestamp}

3. MCP Server (/vscode-response endpoint)
   ├─ Receives POST from VS Code
   ├─ Extracts request_id, result, error
   └─ Calls MCPRepl.store_vscode_response(request_id, result, error)

4. Julia MCP Tool (continued)
   ├─ Polls VSCODE_RESPONSES dict for request_id
   ├─ Waits up to timeout seconds
   └─ Returns (result, error) or throws TimeoutError
```

## Usage Examples

### Basic Fire-and-Forget (Backward Compatible)
```julia
execute_vscode_command("workbench.action.files.saveAll")
# Returns: "VS Code command '...' executed successfully."
```

### Bidirectional with Response
```julia
execute_vscode_command(
    "workbench.debug.action.copyValue",
    wait_for_response=true,
    timeout=10.0
)
# Returns: "VS Code command '...' result:\n{...JSON...}"
```

### With Arguments
```julia
execute_vscode_command(
    "workbench.action.tasks.runTask",
    args=["test"],
    wait_for_response=true
)
```

## User-Facing Changes

### MCP Tool: execute_vscode_command
**New Optional Parameters**:
- `wait_for_response` (boolean, default: false)
- `timeout` (number, default: 5.0)

**Backward Compatibility**: ✅
- Existing calls work unchanged (fire-and-forget mode)
- New functionality opt-in via `wait_for_response=true`

### Extension Installation
**No Changes Required**:
- User calls `MCPRepl.setup()` as before
- Extension auto-upgrades on next install
- Old versions automatically removed

## Next Steps for User

1. **Reinstall Extension** (required for bidirectional support):
   ```julia
   using MCPRepl
   MCPRepl.setup()  # This will reinstall the extension
   ```

2. **Reload VS Code Window** (required to activate new extension):
   - Press Cmd+Shift+P → "Reload Window"
   - Or use: `execute_vscode_command("workbench.action.reloadWindow")`

3. **Test Bidirectional Communication**:
   ```julia
   # Test with a simple command
   result = execute_vscode_command(
       "workbench.action.files.saveAll",
       wait_for_response=true
   )
   println(result)
   ```

## Technical Notes

### Thread Safety
- ReentrantLock protects VSCODE_RESPONSES dict
- Safe for concurrent MCP tool calls

### Memory Management
- Responses auto-deleted on retrieval
- Call `cleanup_old_vscode_responses(60.0)` periodically to prevent leaks
- Could add timer-based cleanup in future

### Error Handling
- VS Code command failures captured and returned
- Network errors logged to console
- Timeout errors properly reported to MCP client

### Port Configuration
- Default MCP port: 3000
- Custom port via `mcp_port` parameter in URI
- Extension reads from query string

## Potential Future Enhancements

1. **Auto-cleanup Timer**: Background task to clean old responses
2. **Request Queue**: Track pending requests for better error messages
3. **Streaming Responses**: For long-running commands
4. **Progress Callbacks**: For multi-step operations
5. **Enhanced copy_debug_value**: Use bidirectional mode automatically

## Files Modified

1. `src/vscode.jl` - Extension generation with POST functionality
2. `src/MCPRepl.jl` - Response storage, URI building, tool enhancement
3. `src/MCPServer.jl` - `/vscode-response` endpoint
4. `NEXT_STEPS.md` - This documentation

## Commit Message

```
Add bidirectional VS Code communication

- Extend VS Code extension to POST command results back to MCP server
- Add /vscode-response endpoint to MCP server (port 3000)
- Implement response storage with thread-safe Dict and polling retrieval
- Add wait_for_response parameter to execute_vscode_command tool
- Support custom timeout and MCP port configuration
- Maintain backward compatibility (fire-and-forget mode)
- Add cleanup mechanism to prevent memory leaks

This enables programmatic retrieval of VS Code command results,
eliminating the manual clipboard workflow for debug values.

Technical: Uses Node.js http.request() to POST from extension,
ReentrantLock for thread safety, and polling retrieval with
configurable timeout.
```

---

## Previous Documentation (for reference)

# Next Steps: Bidirectional VS Code Communication

## Current State ✅
- **Commit**: `d4f4514` - All VS Code Remote Control work committed
- **Features Working**:
  - 19 MCP tools (6 core + 7 developer + 2 optional + 4 debugging)
  - 57 VS Code commands via URI (one-way: Julia → VS Code)
  - VS Code extension: `~/.vscode/extensions/MCPRepl.vscode-remote-control-0.0.1/`
  - Helper functions: `trigger_vscode_uri()`, `build_vscode_uri()`
  - All tests passing (92 tests)

## The Goal 🎯
Enable **bidirectional communication** to GET values from VS Code (not just send commands).

**Use Case**: Programmatically read debug variable values instead of manual clipboard workflow.

## Architectural Decision
**User's Key Insight**: Use existing MCP HTTP server (port 3000) instead of adding new HTTP server to extension.

### Proposed Architecture
1. **Julia → VS Code** (already working): URI commands via `vscode://`
2. **VS Code → Julia** (NEW): Extension POSTs results back to MCP server

```
Julia MCP Server (port 3000)
    ↓ (URI command)
VS Code Extension
    ↓ (HTTP POST with result)
Julia MCP Server (receives response)
```

## Implementation Plan 📋

### Phase 1: Modify VS Code Extension (`src/vscode.jl`)
**File**: `src/vscode.jl` - `install_vscode_remote_control()`

**Changes to `extension.js`**:
```javascript
// After executing command:
const result = await vscode.commands.executeCommand(cmd, ...args);

// POST result back to MCP server
fetch('http://localhost:3000/vscode-response', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    command: cmd,
    result: result,
    timestamp: Date.now()
  })
});
```

**Note**: Current extension is in CommonJS format, uses `vscode.commands.executeCommand()` which CAN return values.

### Phase 2: Add Response Handler to MCP Server (`src/MCPServer.jl`)
**File**: `src/MCPServer.jl`

**Add new endpoint**: `/vscode-response`
```julia
# Handler for VS Code responses
HTTP.register!(router, "POST", "/vscode-response") do req
    body = JSON3.read(String(req.body))
    # Store response in queue/dict for retrieval
    handle_vscode_response(body)
    return HTTP.Response(200, "OK")
end
```

### Phase 3: Update `execute_vscode_command` Tool (`src/MCPRepl.jl`)
**File**: `src/MCPRepl.jl` - `vscode_command_tool` (around line 425)

**Add optional parameter**:
```julia
"wait_for_response" => Dict(
    "type" => "boolean",
    "description" => "Wait for command result (default: false)",
    "default" => false
)
```

**Implementation**: If `wait_for_response=true`, wait for response from queue/callback.

### Phase 4: Test & Document
- Test with debug commands that return values
- Update `copy_debug_value` to use new mechanism
- Document in `julia_repl_workflow.md`

## Alternative: Simple File-Based Approach
If HTTP POST is too complex:
```javascript
// In extension.js:
const fs = require('fs');
const tmpFile = '/tmp/vscode-response.json';
fs.writeFileSync(tmpFile, JSON.stringify(result));
```

Julia reads file after triggering command. Simpler but less elegant.

## Key Files to Modify
1. **`src/vscode.jl`** - Modify `extension.js` generation (line ~93)
2. **`src/MCPServer.jl`** - Add `/vscode-response` endpoint
3. **`src/MCPRepl.jl`** - Update `vscode_command_tool` with response handling

## Technical Notes
- **MCP Server Port**: Currently on 3000 (configurable via setup)
- **Extension URI Scheme**: `vscode://MCPRepl.vscode-remote-control?cmd=...`
- **Extension Location**: Auto-removes old versions before install
- **JSON Library**: Use JSON3.jl throughout for consistency

## Questions to Resolve
1. **Response Storage**: Queue, Dict, or callback-based?
2. **Timeout**: How long to wait for VS Code response?
3. **Error Handling**: What if VS Code command fails?
4. **Multiple Clients**: Handle concurrent requests?

## Starting the Next Session
1. Read this document
2. Review `src/vscode.jl` (extension generation)
3. Review `src/MCPServer.jl` (HTTP server structure)
4. Decide: HTTP POST vs file-based approach
5. Implement Phase 1 (modify extension.js generation)

## Context: Why This Matters
Current limitation of `copy_debug_value`:
- Copies to clipboard
- Agent must run `pbpaste` to read value
- Requires 2-step workflow
- Manual and awkward

With bidirectional communication:
- `execute_vscode_command("workbench.debug.action.copyValue", wait_for_response=true)`
- Returns actual value directly
- Enables full programmatic control

## Commit Before Starting
All current work is committed at `d4f4514`. New work should go in a new commit.
