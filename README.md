# MCPRepl.jl

I strongly believe that REPL-driven development is the best thing you can do in Julia, so AI Agents should learn it too!

MCPRepl.jl is a Julia package which exposes your REPL as an MCP server -- so that the agent can connect to it and execute code in your environment.
The code the Agent sends will show up in the REPL as well as your own commands. You're both working in the same state.


Ideally, this enables the Agent to, for example, execute and fix testsets interactively one by one, circumventing any time-to-first-plot issues.

> [!TIP]
> I am not sure how much work I'll put in this package in the future, check out @kahliburke's much more active [fork](https://github.com/kahliburke/MCPRepl.jl).

## Showcase

https://github.com/user-attachments/assets/1c7546c4-23a3-4528-b222-fc8635af810d

## Installation

This package is not registered in the official Julia General registry due to the security implications of its use. To install it, you must do so directly from the source repository.

You can add the package using the Julia package manager:

```julia
pkg> add https://github.com/hexaeder/MCPRepl.jl
```
or
```julia
pkg> dev https://github.com/hexaeder/MCPRepl.jl
```

## Usage
Within Julia, call
``` julia-repl
julia> using MCPRepl; MCPRepl.start!()
```
to make the REPL discoverable by the adapter.

The MCP server your client connects to is the bundled `mcp-julia-adapter` (a small
stdio script). It discovers running REPLs, routes calls to the right one, and can
even spawn private REPLs for an agent when none is running. Register it once with
Claude Code:
```sh
claude mcp add julia-repl /path/to/MCPRepl/mcp-julia-adapter
```

The easiest way is `MCPRepl.setup()`, an interactive helper that configures Claude
Code / Gemini with the adapter (choose local or user scope).

## Multiple REPLs (multiplexing)

You can run several REPLs at once — e.g. one per project — and agents will route
to the right one automatically. There is **no central daemon**:

- Each `MCPRepl.start!()` binds its own port (the first keeps the historic
  `3000`; later ones take an OS-assigned free port) and advertises itself with a
  small file in `~/.mcprepl/registry/`. Each REPL gets a short, stable
  **word-id** (e.g. `otter`) shown in its startup banner.
- The **adapter** (`mcp-julia-adapter`) is the MCP server and the multiplexer. It
  is launched per-project by the client, reads the registry, and routes each call:
  - a single REPL, or a unique nearest-ancestor of the agent's working
    directory, is used **silently**;
  - if the choice is ambiguous — or a *nearer* REPL appears mid-session — it asks
    **you** to pick, via an MCP elicitation dialog (Claude Code ≥ 2.1.76). The
    LLM is never involved in routing.
  - clients without elicitation get a text prompt listing the REPLs; retry the
    call with an argument `"repl": "<word>"` (or set `MCPREPL_PROJECT=<word>`).
- REPLs in the **same git project** as the agent's working directory (any
  subfolder) are treated as the ideal target — even sibling subfolders.

You can also switch REPLs explicitly:
- **`select-repl` prompt** — an MCP prompt exposed as the slash command
  `/mcp__julia-repl__select-repl` (also listed under `/mcp`). It pops the picker
  on demand, decided by *you*, not the model. Requires a client that surfaces MCP
  prompts and supports elicitation (Claude Code ≥ 2.1.76); reconnect the server
  after upgrading so the prompt is registered.
- **`list_repls` / `select_repl` tools** — the agent can enumerate REPLs and set
  the active one by word-id without any dialog.

Set `MCPREPL_REGISTRY_DIR` to relocate/isolate the registry directory.

### Private (agent-spawned) REPLs

When no suitable REPL is running, an agent can start its own **private** REPL via
the adapter's `spawn_repl` tool: a real interactive Julia session in a detached
`tmux` session (so you can `tmux attach` to watch or take over). It is hidden from
the shared pool, reachable only by its word-id, and auto-killed when the client
session ends (`persist: true` opts out). Kill it explicitly with `kill_repl`.

## Disclaimer and Security Warning

The core functionality of MCPRepl.jl involves opening a network port and executing any code that is sent to it. This is inherently dangerous and borderline stupid, but that's how it is in the great new world of coding agents.

By using this software, you acknowledge and accept the following:

*   **Risk of Arbitrary Code Execution:** Anyone who can connect to the open port will be able to execute arbitrary code on the host machine with the same privileges as the Julia process.
*   **No Warranties:** This software is provided "as is" without any warranties of any kind. The developers are not responsible for any damage, data loss, or other security breaches that may result from its use.

It is strongly recommended that you only use this package on isolated systems or networks where you have complete control over who can access the port. **Use at your own risk.**


## Similar Packages
- [ModelContexProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) offers a way of defining your own servers. Since MCPRepl is using a HTTP server I decieded to not go with this package.

- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) is very similar, but the focus of MCPRepl.jl is to integrate with the user repl so you can see what your agent is doing.
