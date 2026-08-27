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

The MCP server the client connects to is the stdio **`mcp-julia-adapter`**, not the
Julia REPL. Each REPL runs a plain JSON-RPC-over-HTTP endpoint (first REPL on port
3000, later ones on ephemeral ports) that only answers `tools/list`/`tools/call`/
`ping`; the adapter owns the MCP handshake (`initialize`/`serverInfo`), the
`usage_instructions`/`list_repls`/`spawn_repl`/`kill_repl` tools, and all routing.
There is no HTTP transport or OAuth anymore — the adapter is the only supported
transport.

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
- The `mcp-julia-adapter` (script transport) is the router, and routing is
  **stateless**: `resolve` recomputes the target from the live registry on every
  `exec_repl`, keeping **no sticky selection**. An explicit `repl=<word>` (or
  `MCPREPL_PROJECT`) is honored, and a word that no longer resolves is an *error*,
  never a silent fall-back. With no `repl=`: exactly one shared REPL is used
  silently; two or more return a text listing (with a proximity *suggestion*) so
  the caller retries with `repl=<word>` — the adapter never guesses among several.
  The agent carries the word via `repl=`, which keeps routing legible (visible in
  its transcript) instead of hidden in adapter state. Proximity (`repl_rank`,
  `nearest`) is only ever a suggestion in `list_repls`/the ambiguity listing.
- `resolve` also runs a detection-only **identity guard** (`instance_dir`,
  word-id → its first-seen `project_dir`): a same-project restart keeps its
  word-id and rebinds silently, but a word-id recycled onto a *different* project
  (a hash collision, or close-one/open-another) errors once before adopting — so a
  reused word can't silently route to the wrong REPL. There is no `select_repl`
  tool and no elicitation picker (both were part of the old sticky model).
- Tests: `test/adapter_routing_test.py` (fast, run by `Pkg.test()`) and
  `test/integration_multiplex.py` (spawns real Julia servers; run manually).

### Private (agent-spawned) REPLs
- An agent with no REPL can spawn its own **private** REPL via the adapter's
  `spawn_repl` tool: a real interactive Julia REPL running in a detached `tmux`
  session (so `execute_repllike` needs no special headless path — it is a normal
  interactive REPL) and killed via `kill_repl`. The user can `tmux attach` to it.
- Privacy = out-of-pool + owner-discoverable: the REPL's registry record carries
  `private: true`, so it is excluded from the *default-routing pool* — a private
  REPL never becomes the one-shared-REPL default and never appears in the
  ambiguity listing, so it can't hijack the user's shared workflow. It is reached
  **only** by explicitly passing its word-id as the `repl` argument, on every
  call. But discovery and routing are decoupled: `list_repls` DOES show a private
  REPL that *this* adapter spawned (tagged `(private, yours)`, via `owned_by_me`,
  i.e. `owner_pid == getpid()`), so an agent can rediscover its own REPL's word-id
  after a context reset; private REPLs owned by *other* live adapters stay hidden.
  See `is_private`, `owned_by_me`, and the
  `resolve`/`_handle_list_repls`/`_handle_spawn_repl`/`_handle_kill_repl` handlers
  in `mcp-julia-adapter`.
- Because routing is stateless, a private REPL needs no special sticky-case: the
  agent addresses it by `repl=<word>` every call (the word is in its transcript),
  and `list_repls` lets it recover the word-id if it lost it. There is no
  auto-selection on spawn — `spawn_repl` tells the agent to pass `repl=<word>`.
- Session naming: the adapter names each private tmux session
  `mcprepl-<project-label>-<token>` (the project label comes from the spawn's
  project dir via `session_label`, folding a generic leaf like `test` into its
  parent) so `tmux list-sessions` tells you which project each REPL is for. The
  chosen name is passed to Julia via `MCPREPL_TMUX_SESSION` and stored in the
  registry record as `tmux_session`; kill/orphan-reap target that recorded name
  (`record_session`), falling back to the bare `mcprepl-<token>` for old records.
- Kill scope: `kill_repl` can only ever `tmux kill-session` the session named by a
  *registry record* (never a caller-supplied name, never a pid),
  and it refuses both shared REPLs and private REPLs owned by another live adapter
  (`owned_by_live_peer`). Killable: your own, `persist` ones (`owner_pid` 0), and
  orphans whose owner died — the same set the orphan reap claims.
- Lifecycle: private REPLs are auto-killed when the adapter (Claude Code session)
  exits — tracked sessions are reaped on shutdown, with a startup orphan-reap
  (`owner_pid` liveness) as a SIGKILL backstop. `spawn_repl persist=true` opts a
  REPL out to survive for later `tmux attach`.
- Launch uses `--startup-file=no` (so the user's `startup.jl` can't race/clobber
  the private server) and `MCPRepl.start!(private=true)`. Julia fields
  `private`/`spawn_token`/`owner_pid` are written by `register_repl!`.
- The required `project` argument selects the environment (`--project=<realpath>`),
  and the tmux session is started with `-c` in that same directory, so a REPL
  spawned in a nested env (e.g. `NetworkDynamics/test`) gets both the test-env deps
  and a `pwd()` inside `test/`. `using MCPRepl` still resolves in such an env
  because the default `@v#.#` environment stays stacked in the `LOAD_PATH`.
- The adapter also owns `usage_instructions` (sourced from
  `prompts/julia_repl_workflow.md` + `prompts/private_repl_workflow.md`, so it
  works even with zero REPLs) and advertises a teaser via `initialize.instructions`.

### Cancellation (interrupting a running eval)
- The adapter honors MCP `notifications/cancelled` (e.g. the user pressing Esc). It
  posts a plain `interrupt` request to whichever REPL is serving the cancelled
  call; the Julia handler calls `request_interrupt!`, which schedules an
  `InterruptException` onto the REPL backend task — the same primitive as the
  Ctrl-C keybinding. The eval ends with an `InterruptException` and the REPL
  survives for the next call.
- This requires the adapter's stdin reader to stay responsive during a blocking
  eval, so routed calls are forwarded on **worker threads** (`_dispatch_forward` /
  `_forward_worker`), serialized per-REPL by `_PORT_LOCKS`, with the in-flight
  `id -> port` map (`_INFLIGHT`) telling a cancellation where to send the interrupt.
  `HTTP.serve!` on the Julia side already tasks each request separately, so the
  `interrupt` lands while `exec_repl` is mid-eval. On shutdown `drain_workers`
  lets in-flight replies finish (bounded). Interrupts only land at Julia safepoints
  (e.g. allocations, `sleep`, I/O); a truly tight loop with no safepoint may not.

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
