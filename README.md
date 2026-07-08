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
to open the HTTP endpoints.

For Claude Code, you can run the following command to make it aware of the MCP server
```sh
claude mcp add julia-repl http://localhost:3000 --transport http
```

You can also run `MCPRepl.setup()` for an interactive helper that configures
Claude Code / Gemini with either the HTTP transport or the (recommended) script
transport via the bundled `mcp-julia-adapter`.

## Multiple REPLs (multiplexing)

You can run several REPLs at once — e.g. one per project — and agents will route
to the right one automatically. There is **no central daemon**:

- Each `MCPRepl.start!()` binds its own port (the first keeps the historic
  `3000`; later ones take an OS-assigned free port) and advertises itself with a
  small file in `~/.mcprepl/registry/`. Each REPL gets a short, stable
  **word-id** (e.g. `otter`) shown in its startup banner.
- The **script transport** (`mcp-julia-adapter`) is the multiplexer. It is
  launched per-project by the agent, reads the registry, and routes each call:
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

Use the script transport (not the fixed-port HTTP one) if you want multiplexing.
Set `MCPREPL_REGISTRY_DIR` to relocate/isolate the registry directory.

## Disclaimer and Security Warning

The core functionality of MCPRepl.jl involves opening a network port and executing any code that is sent to it. This is inherently dangerous and borderline stupid, but that's how it is in the great new world of coding agents.

By using this software, you acknowledge and accept the following:

*   **Risk of Arbitrary Code Execution:** Anyone who can connect to the open port will be able to execute arbitrary code on the host machine with the same privileges as the Julia process.
*   **No Warranties:** This software is provided "as is" without any warranties of any kind. The developers are not responsible for any damage, data loss, or other security breaches that may result from its use.

It is strongly recommended that you only use this package on isolated systems or networks where you have complete control over who can access the port. **Use at your own risk.**


## Similar Packages
- [ModelContexProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) offers a way of defining your own servers. Since MCPRepl is using a HTTP server I decieded to not go with this package.

- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) is very similar, but the focus of MCPRepl.jl is to integrate with the user repl so you can see what your agent is doing.
