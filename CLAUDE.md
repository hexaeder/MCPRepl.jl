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

### Private (agent-spawned) REPLs
- An agent with no REPL can spawn its own **private** REPL via the adapter's
  `spawn_repl` tool: a real interactive Julia REPL running in a detached `tmux`
  session (so `execute_repllike` needs no special headless path — it is a normal
  interactive REPL) and killed via `kill_repl`. The user can `tmux attach` to it.
- Privacy = hidden + explicit-id: the REPL's registry record carries
  `private: true`, so it is excluded from the pool (auto-routing, `list_repls`,
  the picker) and reachable only by passing its word-id as the `repl` argument.
  See `is_private` and the `resolve`/`_handle_spawn_repl`/`_handle_kill_repl`
  handlers in `mcp-julia-adapter`.
- Lifecycle: private REPLs are auto-killed when the adapter (Claude Code session)
  exits — tracked sessions are reaped on shutdown, with a startup orphan-reap
  (`owner_pid` liveness) as a SIGKILL backstop. `spawn_repl persist=true` opts a
  REPL out to survive for later `tmux attach`.
- Launch uses `--startup-file=no` (so the user's `startup.jl` can't race/clobber
  the private server) and `MCPRepl.start!(private=true)`. Julia fields
  `private`/`spawn_token`/`owner_pid` are written by `register_repl!`.
- The adapter also owns `usage_instructions` (sourced from
  `prompts/julia_repl_workflow.md` + `prompts/private_repl_workflow.md`, so it
  works even with zero REPLs) and advertises a teaser via `initialize.instructions`.

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
