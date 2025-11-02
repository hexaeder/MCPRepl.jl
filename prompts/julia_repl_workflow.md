# Julia REPL Workflow Guide

**New to MCPRepl?** → `usage_quiz()` then `usage_quiz(show_sols=true)` to self-grade

## ⚠️ CRITICAL: Shared REPL Model

**User sees everything you execute in real-time.** You share the same REPL.

**Implications:**
1. **NO `println` to communicate** - User already sees execution. Use TEXT responses.
2. **Default to `q=true` (quiet mode)** - Saves 70-90% tokens by suppressing return values
3. **Use `q=false` ONLY when you need the return value for a decision**

**When to use `q=false`:**
```julia
ex(e="length(result) == 5", q=false)     # ✅ Need boolean to decide next step
ex(e="(actual, expected)", q=false)      # ✅ Need values to compare
ex(e="methods(my_func)", q=false)        # ✅ Need to inspect signatures
```

**Never use `q=false` for:**
```julia
ex(e="x = 42", q=false)                  # ❌ Assignments
ex(e="using Pkg", q=false)               # ❌ Imports
ex(e="function f() ... end", q=false)    # ❌ Definitions
```
---
## Token Efficiency Best Practices

**Batch operations:** `ex("x = 1; y = 2; z = 3")`
**Avoid large outputs:** `ex("result = big_calc(); (length(result), typeof(result))", q=false)`
**Use let blocks:** Keeps workspace clean, only returns final value
**Testing:** `@test` and `@testset` work fine, output is minimal

**Don't:**
- `Pkg.add()` → use `pkg_add(packages=["Name"])`
- `Pkg.activate()` → Never change project
- Display huge arrays with q=false

## Environment & Packages

**Revise.jl** auto-tracks changes in `src/`. If it fails (rare): `restart_repl()`, wait 5-10s, `ping()`
**Session start:** `investigate_environment()` to see packages, dev status, Revise status
**Add packages:** `pkg_add(packages=["Name"])`

## Tool Discovery

**Primary:** `ex()` - Run code, tests, docs, load packages (use for almost everything)

**Julia introspection (DON'T use Read/Grep for these):**
`list_names("Module")`, `type_info("Type")`, `search_methods(func)`

**Code intelligence:** `lsp_find_references()`, `lsp_rename()`, `lsp_code_actions()`

**Utilities:** `format_code(path)`, `ping()`, `investigate_environment()`

**Need help with a tool?** → `tool_help("tool_name")` or `tool_help("tool_name", extended=true)`

## Common Workflows

**Session start:** `investigate_environment()` → check packages → work
**Revise fails:** `restart_repl()` → wait 5-10s → `ping()`
**Testing:** Use `ex()` with `@test` / `@testset`