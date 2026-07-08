# Private (Agent-Spawned) Julia REPLs

The section above introduced private REPLs as one option when no suitable REPL is
running. Here is the detail. If **no** REPL fits your task — or you have a
longer-running task where you want to keep live state — you can start your own
**private** REPL with the `spawn_repl` tool. This refines the "never start/kill a
shared server" rule above: you MAY
manage *your own private* REPL, but **only** through the `spawn_repl` / `kill_repl`
tools (never via `julia`/`pkill`/`kill` in bash, and never touch the user's
shared REPL).

A private REPL is a real interactive Julia session running in a detached tmux
session. From Julia's side it behaves exactly like a shared REPL; it is simply
hidden from the shared pool and reachable only by its word-id.

## When to use one

- **Longer-running / live-state work.** Run a simulation, a fit, a long build in
  the REPL. If it fails, the REPL is still sitting there with the **full
  post-mortem state** — variables, the stacktrace, partial results — so you can
  investigate interactively (`@show x`, inspect `err`, re-run one line) instead of
  re-running a cold script and sprinkling print statements.
- **Avoiding TTFX.** You pay Julia's startup + precompilation cost **once**, then
  every `exec_repl` call is warm — far faster than repeatedly shelling out to
  `julia somescript.jl`.

## How to use one

1. **Spawn:** call `spawn_repl` with `project` set to the Julia project you want
   (a directory or a `Project.toml`). It returns a **word-id**.
2. **Route to it:** pass that word-id as the `repl` argument on `exec_repl`
   (or call `select_repl` once with `repl=<word>` to make it sticky). The private
   REPL does **not** appear in `list_repls`.
3. **Kill it:** call `kill_repl` with the word-id when you're done. It is also
   **auto-killed when your session ends** (unless you spawned it with
   `persist: true`), so you won't leak background processes.
4. The user can `tmux attach` to the session at any time to watch or take over.

## Environment rules (same as a shared REPL)

- **Never mutate the environment from inside the REPL.** `Pkg.add` and
  `Pkg.activate` are blocked here just as in a shared REPL — the private REPL is
  born with the correct `--project`, so there is never a reason to re-activate.
- **To change dependencies:** `kill_repl` the REPL, then `spawn_repl` a new one
  (optionally after the user updates the project). Do **not** add packages just to
  debug something — that is almost always a no-go, and you must **ask the user**
  before adding any dependency.
