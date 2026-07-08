# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# MCPRepl Project

This project provides an MCP server that bridges Claude Code to a running Julia REPL session for interactive development.

## Core Architecture

- **MCPRepl.jl**: Main module with REPL execution engine and server management
- **MCPServer.jl**: HTTP server implementing MCP (Model Context Protocol) with JSON-RPC 2.0
- **execute_repllike()**: Core function that captures and executes Julia code in the active REPL session

The server provides:
- `exec_repl` tool for remote execution of Julia expressions while preserving REPL state
- `remove-trailing-whitespace` tool for cleaning up trailing whitespace in files after edits

## Development Commands

### Testing
```bash
julia --project -e "using Pkg; Pkg.test()"
```

### Manual Testing  
Start Julia REPL in project directory:
```bash
julia --project
```

Then start the MCP server:
```julia
using MCPRepl
MCPRepl.start!()  # Starts on port 3000
MCPRepl.stop!()   # Stop server when done
```

## MCP Server Configuration

The MCP server runs on `http://localhost:3000` and provides tools for Julia development.

### Server Management
- **MCPRepl.start!()**: Starts a server and registers it for discovery. Binds
  port 3000 when free, otherwise an OS-assigned ephemeral port (so multiple
  REPLs can coexist). Assigns a stable word-id and writes a registry file.
- **MCPRepl.stop!()**: Stops the running server and removes its registry file.
- Only one server instance runs per Julia process (start! stops an existing one
  first), but several Julia processes can each run their own server.

### Multiplexing across REPLs
- Each REPL advertises itself in `~/.mcprepl/registry/<pid>.json` (override the
  directory with `MCPREPL_REGISTRY_DIR`). See `registry_dir`, `register_repl!`,
  `unregister_repl!`, `wordid_for`, and `choose_port` in `src/MCPRepl.jl`.
- The `mcp-julia-adapter` (script transport) is the router: it discovers live
  REPLs and routes each call, prompting the user via MCP elicitation only when
  the target is genuinely ambiguous. Julia stays a plain HTTP endpoint; all
  routing lives in the adapter.
- Tests: `test/adapter_routing_test.py` (fast, run by `Pkg.test()`) and
  `test/integration_multiplex.py` (spawns real Julia servers; run manually).

### Tool Capabilities

#### `exec_repl` tool:
- Executes Julia expressions in the active REPL backend
- Captures stdout, stderr, and display output
- Maintains REPL state between calls
- Supports Revise.jl for hot reloading of source changes
- Respects semicolon suppression for output

#### `remove-trailing-whitespace` tool:
- Removes trailing whitespace from all lines in a file
- Should be called after AI agents edit files to clean up any trailing spaces
- For single file edits: Call immediately after editing
- For multiple file edits: Call once on each modified file at the very end, before handing back to the user
- Uses `sed` to efficiently remove whitespace similar to Emacs `delete-trailing-whitespace`
- Handles all types of trailing whitespace (spaces, tabs, mixed)


## Important Constraints

- **NEVER start the MCP server yourself** using Bash or other tools - always tell the user to start it manually
- The server shares the user's REPL session in real-time, so be respectful of workspace
- Struct and constant redefinitions require REPL restart (Revise limitation)
- Never use `Pkg.activate` - assume you're in the correct environment
- Ask before long-running operations (>5 seconds)
