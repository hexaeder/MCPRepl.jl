# Julia REPL Workflow

This guide teaches AI agents how to use the Julia REPL bridge effectively: how it
is structured (one adapter, possibly several REPLs), when to reach for it, how to
route to the right REPL, and how to work respectfully in a REPL a human shares
with you.

## How this bridge is structured

You are talking to an **adapter** (the MCP server). Behind it there can be
**zero, one, or several** running Julia REPLs — each a separate Julia process with
its own project, its own live state, identified by a short **word-id** (e.g.
`otter`). The adapter discovers them and routes each `exec_repl` call to one of
them.

This means the REPL tools existing does **not** guarantee a REPL is running. Your
first move in a session is to find out what is actually there:

1. Call **`list_repls`** to see the running REPLs — their word-id, working
   directory, project, and port. The one nearest your working directory is
   flagged as a *suggestion*.
2. Sanity-check that the REPL you intend to use has a project/directory matching
   the code you are about to work on. A REPL in the wrong project is worse than no
   REPL.

**Routing is explicit and stateless — there is no sticky "current REPL".** You
choose per call by passing **`repl=<word>`** on `exec_repl`, and you keep passing
it. The only shortcut: if exactly **one** shared REPL is running, a call with no
`repl=` uses it. With **two or more**, a call without `repl=` does *not* guess —
it returns the list so you pick one; route the rest of your calls with that
word-id. Because there is no hidden selection, the word you pass is always visible
in your own transcript — that *is* the source of truth for which REPL you're on.

If a `repl=<word>` no longer names a live REPL (it exited), the call **errors**
rather than silently falling back to a different REPL — re-check `list_repls` and
pick another. (Word-ids are derived from the project path and stable across a
restart, so a restarted REPL keeps its word.)

## Do you even need the REPL?

Prefer the REPL for anything **iterative or stateful** — exploring an API,
re-running a function as you edit it (Revise hot-reloads `src/`), inspecting
values, running targeted tests. You pay Julia's startup + precompilation cost
once and every later call is warm.

But **not every task needs a REPL.** A self-contained one-shot — run a script,
produce a file, check a version — is often cleaner as a plain bash call:

```bash
julia --project=<path> --startup-file=no somescript.jl
```

Always pass **`--startup-file=no`** when you shell out to `julia` yourself, so the
user's `startup.jl` (which may auto-start a REPL server, change the environment,
etc.) doesn't interfere with your one-shot.

## When no suitable REPL is running

If `list_repls` shows nothing that fits your task, you have three options — choose
based on the situation, and when in doubt **ask the user**:

- **Ask the user to open a shared REPL.** Best when you'll be collaborating in the
  user's live session, or the task benefits from them watching/steering. You never
  start a shared REPL yourself.
- **Spawn your own private REPL** with `spawn_repl`. Best for longer-running or
  stateful work you own end-to-end (a simulation you want to inspect if it fails).
  See the private-REPL section below.
- **Just use `julia --project=… --startup-file=no`** for a quick one-shot, as
  above.

## Server management (shared REPLs)

Shared REPLs — the ones a human started — are **the user's** to manage:

- **NEVER** start a shared REPL yourself (`julia -e "using MCPRepl; start!()"`).
- **NEVER** kill Julia processes with `pkill`/`kill`, and **NEVER** call
  `MCPRepl.stop!()` via `exec_repl`.
- When a shared REPL is broken or missing, say so and ask the user to fix or start
  it — don't silently work around it.

The one exception is a **private REPL you spawned yourself**, which you may manage
*only* through the `spawn_repl` / `kill_repl` tools (never via bash). See below.

## Shared REPL etiquette

- The REPL is shared with the user in real time. Minimize clutter; clean up
  variables they don't need; ask before operations that run longer than a few
  seconds.
- **The REPL is for information gathering, not for talking to the user.** All
  communication happens in the chat. The user can see REPL activity, but don't
  narrate to them through it:
  - ✅ Let expressions return values; use `@show`/`println` when *you* need to
    inspect something; run tests whose output *you* read.
  - ❌ Don't add `println("Starting…")` / `@info "Checking…"` to update the user —
    report findings in chat instead.

## Long-running calls

An `exec_repl` call stays open until the code finishes, however long that takes;
the adapter keeps the call alive with progress notifications. Some clients (e.g.
Claude Code) move a long call into the background and deliver its result as a
notification when it completes. Just wait for that result. Don't watch the tmux
session or poll the REPL to find out whether it's done.

Calls to the same REPL run one at a time. If you send another `exec_repl` while
one is still running, it waits for the first to finish.

## Revise.jl integration

- Edits to functions in a package's `src/` (or `ext/`) are picked up automatically.
- **Struct and constant redefinitions require a REPL restart** — ask the user (for
  a shared REPL) or restart your private one.
- **Never `include` a package's `src/`/`ext/` files** — use `using`/`import` and
  let Revise handle reloading. Direct `include` corrupts module state.
- If a change isn't picked up, try `Revise.retry()`; if it still isn't, stop and
  ask the user (shared REPL) rather than guessing.

## Best practices

### Keep global scope clean — use `let`

```julia
let x = 10, y = 20
    result = x + y
    @show result
end
```

### Name hygiene — don't prototype under the name you'll ship

A definition you make in the REPL lands in `Main` and **shadows** the package's
own binding of that name. So if you prototype `future_library_function` in the
REPL and then add the real one to `Package/src/`, calling
`future_library_function` still hits your REPL version — `using Package` will not
overwrite an existing `Main` binding, and Revise can't fix it either. The name is
now blocked for the rest of the session, and you can easily fool yourself into
thinking you tested the implementation when you tested the prototype.

Prototype under a throwaway name instead, and redefine that freely while you
iterate:

```julia
future_library_function_mcp123(x) = ...   # scratch name, free to redefine
```

Once you're happy, write the real definition into `src/` under its final name and
call it fully qualified (`Package.future_library_function`) to be sure you're
exercising the package version.

### Testing — avoid `Pkg.test()` (too slow); target instead

```julia
@testset "My Feature" begin
    @test my_function(1) == 2
    @test_throws ArgumentError my_function(-1)
end
```

### Check documentation before using unfamiliar APIs

```julia
@doc function_name
names(PackageName)     # what a package exports
@which sort([1,2,3])   # which method runs
methods(sort)
```

### Iterating on a non-trivial snippet — use a scratch file

For a small, one-off expression, send it inline with `exec_repl`. But when you
find yourself re-sending a substantial block (roughly >20 lines) and tweaking a
few lines each time, write it to a scratch file in your **session scratchpad**,
edit it surgically with your file tools, and re-run with
`include(".../scratch.jl")`.

Re-`include`ing is usually cheap: after the first run the code is compiled, which
is exactly the warm-REPL (TTFX) win — the first pass can easily take 10× a later
one. Only genuinely per-run-expensive work (loading a large dataset, a long
simulation) is worth keeping as REPL state you run once, rather than re-running it
inside the script. (This is unrelated to the rule against `include`-ing a
package's `src/`/`ext/` files — a throwaway scratch script is fine.)

### Large or noisy output — redirect to a file

When a call prints a lot (a test suite, a simulation), redirect it to a file in
your scratchpad instead of pulling the whole dump into context, then inspect it
with **your own Read/Grep tools**:

```julia
open(".../out.txt", "w") do io
    redirect_stdout(io) do
        include(".../scratch.jl")
    end
end
```

Only bother when output is genuinely large — for a few lines, let it return
inline. Don't shell out through the REPL (`run(`grep …`)`) to search it; that's
what your own tools are for.

## Environment management

Call the **`investigate_environment`** tool at the start of REPL work: it reports
the working directory, active project, packages (including Revise-tracked dev
packages and their paths), and Revise status. Use it to confirm the environment is
plausible *before* assuming a package is available.

You can also inspect manually (read-only):

```julia
using Pkg; Pkg.status()
VERSION; versioninfo()
```

**The environment is read-only.** Never modify it from inside the REPL:

```julia
Pkg.activate(".")       # ❌ blocked — stay in the current environment
Pkg.add("SomePackage")  # ❌ blocked — assume deps are installed
Pkg.test()              # ❌ usually too slow — ask first
```

If a required package is missing: check `Pkg.status()`, then **stop and ask the
user** to prepare an environment with the packages you need — naming each and why.
Do not install anything yourself. (For a private REPL, the way to change deps is to
`kill_repl` and `spawn_repl` with an updated project — again, ask first.)

## Development cycle

1. **Edit** source files in `src/`.
2. **Exercise** the change with specific function calls (Revise reloads it).
3. **Verify** with `@doc` / `@which` and targeted `@testset` blocks.
4. **Report** findings in chat.
