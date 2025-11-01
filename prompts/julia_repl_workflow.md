# Julia REPL Workflow Guide

## 📝 New to MCPRepl? Take the Quiz!

**Before working with users, verify your understanding:**

```julia
usage_quiz()              # Answer 6 questions about core concepts
usage_quiz(show_sols=true)  # Check answers and grade yourself
```

**Must score 75+ to ensure token-efficient, effective usage.** The quiz takes 5-10 minutes and will help you save 70-90% of tokens.

---

## ⚠️ CRITICAL: Understand the Shared REPL Model

**THIS IS THE MOST IMPORTANT CONCEPT TO UNDERSTAND.**

### The User Sees Everything You Execute In Real-Time

You and the user are working in the **SAME REPL**. When you execute code:
- It appears in their REPL **immediately**
- They see the **same output** you see
- There is **NO SEPARATION** between your view and theirs

**IMPLICATIONS:**

1. **DO NOT add `println` statements to "communicate" with the user**
   - ❌ WRONG: `ex(e="println('Testing mean function'); mean(data)")`
   - ✅ RIGHT: Write explanations in your TEXT response, not in code
   - **Why:** The user already sees `mean(data)` execute in their REPL. Adding `println` is redundant noise.

2. **Use your TEXT responses to explain, NOT code**
   - **TEXT (outside tool calls):** "Let me test the mean function to verify it's working:"
   - **CODE:** `ex(e="mean(test_data)", q=false)`
   - The user reads your TEXT for context, sees the code execute in their REPL in real-time.

3. **Default to quiet mode (`q=true`, the default)**
   - ❌ WRONG: `ex(e="test_data = [1,2,3,4,5]", q=false)`  # Wastes tokens showing the vector
   - ✅ RIGHT: `ex(e="test_data = [1,2,3,4,5]")`  # User sees it execute, you don't need the return value

### When to Use `q=false` (Verbose Mode)

**ONLY use `q=false` when you need the return value to make a decision.** This should be **RARE**.

**Valid uses of `q=false`:**
```julia
# You need to inspect the result to decide if there's a bug
ex(e="length(result)", q=false)  # Need to see: is it 2 or 3?

# You need multiple values for comparison
ex(e="(actual_value, expected_value)", q=false)

# You need to see the output to determine next steps
ex(e="methods(my_function)", q=false)
```

**INVALID uses of `q=false` (wasteful):**
```julia
# ❌ Assignment - you don't need to see the value
ex(e="x = 42", q=false)

# ❌ Loading modules - no return value needed
ex(e="using Package", q=false)

# ❌ Defining functions - you don't need to see the return value
ex(e="function foo() ... end", q=false)

# ❌ "Showing the user what happened" - they already see it!
ex(e="println('Result: ', result)", q=false)
```

### Communication Channels

**Understand where to communicate what:**

| Purpose | Where | Example |
|---------|-------|---------|
| Explain what you're doing | **Your TEXT response** | "Let me test the moving average function:" |
| Execute actions | **`ex` tool with `q=true`** | `ex(e="result = moving_average(data, 3)")` |
| Inspect values for decisions | **`ex` tool with `q=false`** | `ex(e="length(result)", q=false)` |
| Debug output | **User's REPL** (automatic) | They see everything you execute |

### Example: Good vs Bad Workflow

**❌ BAD (wasteful, redundant):**
```julia
ex(e="println('Loading module...'); include('StatsUtils.jl')", q=false)
ex(e="println('Creating test data...'); test_data = [1,2,3,4,5]", q=false)
ex(e="println('Testing mean:'); mean(test_data)", q=false)
ex(e="println('Result:', result)", q=false)
```
**Token waste:** ~500 tokens
**Problems:** Redundant printlns, unnecessary q=false, poor communication

**✅ GOOD (efficient, clear):**

**Your TEXT:** "Let me load the module and test the mean function:"
```julia
ex(e="include('StatsUtils.jl')")
ex(e="using .StatsUtils")
ex(e="test_data = [1,2,3,4,5]")
ex(e="mean(test_data)", q=false)  # Need to see the result
```
**Token waste:** ~50 tokens
**Benefits:** 90% token savings, clear communication, user sees everything in their REPL

---

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

## 🚀 Token Efficiency - CRITICAL for Performance

**AI agents must be token-efficient!** Every character returned from `exec_repl` counts against your context budget.

### Use Semicolons to Suppress Unwanted Output

**The semicolon is your best friend for token efficiency:**

```julia
# ❌ WASTEFUL - Returns "test_func (generic function with 1 method)"
function test_func(x) x * 2 end

# ✅ EFFICIENT - Returns nothing (suppressed)
function test_func(x) x * 2 end;

# ❌ WASTEFUL - Returns "42"
x = 42

# ✅ EFFICIENT - Returns nothing
x = 42;

# ❌ WASTEFUL - Returns large TestSet object
@testset "Tests" begin @test 1+1 == 2 end

# ✅ EFFICIENT - Returns just test summary
@testset "Tests" begin @test 1+1 == 2 end;
```

### Avoid Displaying Large Data Structures

```julia
# ❌ WASTEFUL - Prints all 100 elements (100+ tokens!)
collect(1:100)

# ✅ EFFICIENT - Suppressed with semicolon
collect(1:100);

# ✅ EFFICIENT - Returns just "100"
length(collect(1:100))

# ❌ WASTEFUL - Prints entire array
big_result = expensive_computation()

# ✅ EFFICIENT - Suppress output
big_result = expensive_computation();
```

### The `silent` Parameter Does NOT Save Tokens

```julia
# ⚠️ MISCONCEPTION: silent=true saves tokens
# REALITY: silent only suppresses the "agent>" prompt in the REPL
# It does NOT reduce the returned output!

# These return the SAME output to you:
@doc sin                    # Returns full documentation
@doc sin, silent=true       # Returns full documentation (same tokens!)

# Use silent only to avoid cluttering the user's REPL view
# NOT for token efficiency
```

### Combine Operations in Single Calls

```julia
# ❌ INEFFICIENT - Multiple tool calls
exec_repl("x = 1")
exec_repl("y = 2")
exec_repl("z = 3")

# ✅ EFFICIENT - One call with semicolons
exec_repl("x = 1; y = 2; z = 3;")
```

## ✅ Best Practices

### Quick Testing (Preferred)
```julia
# Inline tests (suppress result with semicolon if you don't need confirmation)
@test my_function(5) == 6;  # Just runs test, no output returned

# Specific test sets (always use semicolon to suppress TestSet object!)
@testset "Feature X" begin
    @test condition1
    @test condition2
end;  # ← Semicolon prevents returning large TestSet object
```

### Temporary Computations
```julia
# Use let blocks - they only return the final result
let x = load_data(), y = process(x)
    result = analyze(y)
    println("Result: $result")
end;  # ← Suppress the return value if you don't need it
```

### Documentation Lookup
```julia
# These are inherently verbose - only call when needed
@doc function_name    # Returns full docs (many tokens)
methods(sort)         # Returns all method signatures (many tokens)
@which my_function(arg)  # Concise, fine to use
```

## ❌ What NOT to Do

```julia
Pkg.add("Package")        # ❌ Use pkg_add() instead
Pkg.activate(".")         # ❌ Never change active project
Pkg.test()                # ❌ Usually too slow, ask first

x = 1; y = 2; z = 3      # ❌ Don't clutter workspace (use let blocks or semicolons)
# include("entire_file.jl") # ❌ Prefer targeted execution (commented to avoid false diagnostics)
```

## 💡 Practical Token-Saving Examples

```julia
# ❌ WASTEFUL - 3 tool calls, returns 3 values
exec_repl("x = 10")
exec_repl("y = 20")
exec_repl("x + y")

# ✅ EFFICIENT - 1 tool call, returns only result
exec_repl("x = 10; y = 20; x + y")

# ❌ WASTEFUL - Returns giant TestSet object
exec_repl("@testset \"Tests\" begin @test f(5)==10 end")

# ✅ EFFICIENT - Returns just test summary
exec_repl("@testset \"Tests\" begin @test f(5)==10 end;")

# ❌ WASTEFUL - Displays entire 1000-element array
exec_repl("result = big_computation()")

# ✅ EFFICIENT - Suppress display, verify with summary
exec_repl("result = big_computation(); (length(result), typeof(result))")
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
    # include("test/runtests.jl")  # Example - adjust path as needed
end;  # ← Always use semicolon to suppress TestSet return value!
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

## 🎓 Key Takeaways for AI Agents

1. **Use semicolons liberally** - They suppress unwanted return values and save massive amounts of tokens
2. **Combine operations** - Multiple assignments in one `exec_repl` call is more efficient
3. **Suppress TestSet objects** - Always end `@testset` with a semicolon
4. **Be cautious with docs** - `@doc` and `methods()` return verbose output
5. **`silent=true` is NOT for token savings** - It only affects the user's REPL display
6. **Use `let` blocks** - They keep workspace clean and return only the final result
7. **Verify without displaying** - Use `length()`, `typeof()`, etc. instead of displaying huge arrays

**Token efficiency is critical for long conversations. Every token counts!**
