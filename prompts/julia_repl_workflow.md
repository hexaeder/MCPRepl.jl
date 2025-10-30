# Julia REPL Workflow Guide

## 🎯 Core Principles

### 1. The REPL is Shared
- The user can see everything you execute in real-time
- Keep the workspace clean - use `let` blocks for temporary work
- The REPL state persists across all your tool calls

### 2. Revise.jl Tracks Changes Automatically
- Edits to Julia files in `src/` are picked up automatically
- **Rare exception**: If Revise fails to pick up a change, use `restart_repl()`
- Always use `investigate_environment` at session start to see what's being tracked

### 3. Package Management
- Use `pkg_add(packages=["PackageName"])` to add packages when needed
- Check with `investigate_environment` to see what's already available

## ✅ Best Practices

### Quick Testing (Preferred)
```julia
# Inline tests
@test my_function(5) == 6
@test_throws ArgumentError bad_input()

# Specific test sets
@testset "Feature X" begin
    @test condition1
    @test condition2
end
```

### Temporary Computations
```julia
# Use let blocks to avoid polluting the workspace
let x = load_data(), y = process(x)
    result = analyze(y)
    println("Result: $result")
end
```

### Documentation Lookup
```julia
@doc function_name
methods(sort)
@which my_function(arg)
```

## ❌ What NOT to Do

```julia
Pkg.add("Package")        # ❌ Use pkg_add() instead
Pkg.activate(".")         # ❌ Never change active project
Pkg.test()                # ❌ Usually too slow, ask first

x = 1; y = 2; z = 3      # ❌ Don't clutter workspace
include("entire_file.jl") # ❌ Prefer targeted execution
```

## 🔧 When to Use Each Tool

### `exec_repl` - Run Julia Code (PRIMARY TOOL)
**Use this for almost everything:**
- Testing functions after editing them
- Running code blocks to verify behavior
- Checking documentation (`@doc`, `methods`, `@which`)
- Interactive exploration and experimentation
- Running test sets (`@testset`)
- Loading packages (`using PackageName`)

**This is your main interface to Julia - use it extensively!**

### `execute_vscode_command` - VS Code Actions (Rare)
- `"editor.debug.action.toggleBreakpoint"` - Set/remove breakpoints
- `"workbench.view.debug"` - Open debug panel
- `"workbench.action.debug.start"` - Start debugging session

### `restart_repl` - Restart Julia REPL
- Only if Revise fails to pick up a change (rare)
- Returns immediately, wait 5-10 seconds before next request
- REPL state will be cleared

### `investigate_environment` - Understand Setup
- Call at start of Julia sessions
- Shows active packages, dev packages, Revise status
- Helps you understand what's available

## � Debugging Tools

Set breakpoints and step through code:
```julia
# Open debug view
execute_vscode_command("workbench.view.debug")

# Toggle breakpoint at cursor
execute_vscode_command("editor.debug.action.toggleBreakpoint")

# Start debugging
execute_vscode_command("workbench.action.debug.start")

# Step commands (when paused)
execute_vscode_command("workbench.action.debug.stepOver")   # F10
execute_vscode_command("workbench.action.debug.stepInto")   # F11
execute_vscode_command("workbench.action.debug.stepOut")    # Shift+F11
execute_vscode_command("workbench.action.debug.continue")   # F5
```

## 🔍 LSP Tools for Code Intelligence

```julia
# Jump to definition
lsp_goto_definition(file_path="/path/to/file.jl", line=42, column=10)

# Find all references
lsp_find_references(file_path="/path/to/file.jl", line=42, column=10)

# Rename symbol everywhere
lsp_rename(file_path="/path/to/file.jl", line=42, column=10, new_name="better_name")

# Format file
lsp_format_document(file_path="/path/to/file.jl")

# Get available fixes
lsp_code_actions(file_path="/path/to/file.jl", start_line=42, start_column=10)
```

## 📋 Common Workflows

**Starting a session:**
1. `investigate_environment` - see what's available
2. Check if required packages are present
3. Start working

**If Revise fails to pick up changes (rare):**
```julia
restart_repl()
# Wait 5-10 seconds for restart, then reload package
```

**Running full test suite:**
```julia
# Usually better to run targeted tests via exec_repl
# For full suite, ask user first (it's slow)
@testset "All Tests" begin
    include("test/runtests.jl")
end
```

## 🐛 Debugging (Advanced)

Set breakpoints and step through code:
```julia
# Open debug view
execute_vscode_command("workbench.view.debug")

# Toggle breakpoint at cursor
execute_vscode_command("editor.debug.action.toggleBreakpoint")

# Start debugging
execute_vscode_command("workbench.action.debug.start")

# Step commands (when paused)
execute_vscode_command("workbench.action.debug.stepOver")   # F10
execute_vscode_command("workbench.action.debug.stepInto")   # F11
execute_vscode_command("workbench.action.debug.stepOut")    # Shift+F11
execute_vscode_command("workbench.action.debug.continue")   # F5
```

---

**Key Insight**: Prefer quick, targeted tests over full test suites. Use MCP tools over alternatives. Keep the REPL clean.
