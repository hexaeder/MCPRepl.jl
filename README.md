# MCPRepl.jl

I strongly believe that REPL-driven development is the best thing you can do in Julia, so AI Agents should learn it too!

MCPRepl.jl is a Julia package which exposes your REPL as an MCP server -- so that the agent can connect to it and execute code in your environment.
The code the Agent sends will show up in the REPL as well as your own commands. You're both working in the same state.


Ideally, this enables the Agent to, for example, execute and fix testsets interactively one by one, circumventing any time-to-first-plot issues.

> [!TIP]
> @kahliburke's fork has since grown into [Kaimon.jl](https://github.com/kahliburke/Kaimon.jl), a far more
> capable (but also more complex) take on the same idea. Check it out if you want more than a shared REPL.
>
> MCPRepl.jl itself stays small. I use it daily and keep it maintained, but there are no plans to register it.

## Showcase

https://github.com/user-attachments/assets/1c7546c4-23a3-4528-b222-fc8635af810d

## Installation

This package is not registered in the General registry, and there are no plans to change that.
Add it straight from GitHub to your global environment, so it is available in every project:

```julia
pkg> add https://github.com/hexaeder/MCPRepl.jl
```

Since it is not registered, `Pkg` won't tell you about new versions. Run `pkg> update MCPRepl`
every now and then to pick up fixes.

## Usage

### 1. Start the server from your `startup.jl`

Every REPL that should be reachable by an agent needs to call `MCPRepl.start!()`. The easiest
way is to do it in `~/.julia/config/startup.jl`:

```julia
if Base.isinteractive()
    try
        import MCPRepl
        MCPRepl.start!()
    catch e
        println("Failed to start MCPRepl: $e")
    end
end
```

The code the agent sends shows up in your REPL next to your own commands.

### 2. Install the adapter in your coding agent (once)

Your coding agent does not talk to the REPL directly. It launches the bundled
`mcp-julia-adapter` (a small stdio MCP server), which finds the running REPLs and routes
calls to them. Register it once by calling

```julia
julia> import MCPRepl; MCPRepl.setup()
```

This is an interactive helper that configures Claude Code, Gemini or Codex (pick the scope in
the menu). For Claude Code you can also do it by hand:
```sh
claude mcp add julia-repl /path/to/MCPRepl/mcp-julia-adapter
```

That's it. If no REPL is running at all, the agent can also spawn its own private REPL in a
`tmux` session (see [Private REPLs](#private-agent-spawned-repls)).

### Codex

Use `MCPRepl.setup()` or configure Codex directly from Julia:

```julia
MCPRepl.configure_codex("user")     # All projects
MCPRepl.configure_codex("project")  # Current directory
# Or choose a project explicitly:
MCPRepl.configure_codex("project"; project_dir="/path/to/project")
```

User scope writes `~/.codex/config.toml` (or `$CODEX_HOME/config.toml` when set).
Project scope writes `.codex/config.toml` inside the chosen directory. Run setup
from the project root to make it available throughout that project. Codex loads
project configuration only for trusted projects; see the
[Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
The configuration is shared by Codex CLI and IDE clients, and setup does not
require the Codex executable to be installed.

Existing settings and other MCP servers are preserved. Reinstalling replaces
the `julia-repl` entry in the selected scope. Modified files are backed up to
`config.toml.bak`; TOML formatting and comments are not retained in the rewritten
file. Invalid TOML is reported without overwriting the file.

To remove the adapter from one scope, call `MCPRepl.remove_codex("user")` or
`MCPRepl.remove_codex("project"; project_dir="/path/to/project")`.

## Multiple REPLs (multiplexing)

You can run several REPLs at once — e.g. one per project — and agents will route
to the right one automatically. There is **no central daemon**:

- Each `MCPRepl.start!()` binds its own port (the first keeps the historic
  `3000`; later ones take an OS-assigned free port) and advertises itself with a
  small file in `~/.mcprepl/registry/`. Each REPL gets a short, stable
  **word-id** (e.g. `otter`) shown in its startup banner.
- The **adapter** (`mcp-julia-adapter`) is the MCP server and the multiplexer. It
  is launched per-project by the client, reads the registry, and routes each call.
  Routing is **explicit and stateless** — there is no sticky "current REPL":
  - an explicit `"repl": "<word>"` argument (or `MCPREPL_PROJECT=<word>`) is
    always honored; a word that no longer names a live REPL is an **error**, not a
    silent fall-back to a different one;
  - with no `repl` argument, a **single** shared REPL is used silently; with **two
    or more** the adapter returns a text listing (flagging the nearest one as a
    suggestion) and the agent retries with `"repl": "<word>"`. It never guesses
    among several, and the LLM/adapter never picks silently for you.
  - the agent keeps passing that word-id on subsequent calls; because there's no
    hidden state, which REPL it's using is always visible in its own transcript.
- REPLs in the **same git project** as the agent's working directory (any
  subfolder) rank as the nearest suggestion — even sibling subfolders.
- **`list_repls` tool** — enumerate the running REPLs (word-id, dir, project,
  port) with the nearest one flagged. There is no `select_repl` tool or picker
  prompt: routing is done per call via the `repl` argument, not a stored selection.

Set `MCPREPL_REGISTRY_DIR` to relocate/isolate the registry directory.

### Private (agent-spawned) REPLs

When no suitable REPL is running, an agent can start its own **private** REPL via
the adapter's `spawn_repl` tool: a real interactive Julia session in a detached
`tmux` session (so you can `tmux attach` to watch or take over). It is hidden from
the shared pool, reachable only by its word-id, and auto-killed when the client
session ends (`persist: true` opts out). Kill it explicitly with `kill_repl`.

### Cancelling a running eval

The adapter honors MCP cancellation (e.g. pressing Esc in Claude Code): it
interrupts the running Julia eval — scheduling an `InterruptException` onto the
backend, just like Ctrl-C — instead of leaving it to run to completion. The REPL
survives and is ready for the next call. (Interrupts land at Julia safepoints, so
a tight loop with no allocation/`sleep`/I/O may not be interruptible.)

## Disclaimer and Security Warning

The core functionality of MCPRepl.jl involves opening a network port and executing any code that is sent to it. This is inherently dangerous and borderline stupid, but that's how it is in the great new world of coding agents.

By using this software, you acknowledge and accept the following:

*   **Risk of Arbitrary Code Execution:** Anyone who can connect to the open port will be able to execute arbitrary code on the host machine with the same privileges as the Julia process.
*   **No Warranties:** This software is provided "as is" without any warranties of any kind. The developers are not responsible for any damage, data loss, or other security breaches that may result from its use.

It is strongly recommended that you only use this package on isolated systems or networks where you have complete control over who can access the port. **Use at your own risk.**


## Similar Packages
- [ModelContexProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) offers a way of defining your own servers. Since MCPRepl is using a HTTP server I decieded to not go with this package.

- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) is very similar, but the focus of MCPRepl.jl is to integrate with the user repl so you can see what your agent is doing.
