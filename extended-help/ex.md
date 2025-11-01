# Extended Help: ex (Execute Julia REPL)

## Overview

The `ex` tool executes Julia code in a persistent REPL session. It uses short parameter names to save tokens:
- `e` - expression (required)
- `q` - quiet mode (default: true)
- `s` - silent mode (default: false)

## Token-Efficient Usage Patterns

The `ex` tool is your primary interface to Julia. Using it efficiently saves massive amounts of tokens.

### 🚀 Quiet Mode (Default Behavior)

**By default, `ex` automatically suppresses return values to save tokens:**

```julia
# ✅ DEFAULT (q=true) - Returns only printed output, no return value
ex(e="x = 42")                              # Returns: ""
ex(e="function test_func(x) x * 2 end")    # Returns: ""
ex(e="using DataFrames")                    # Returns: ""

# When you NEED the return value, use q=false:
ex(e="2 + 2", q=false)                      # Returns: "4"
ex(e="typeof([1,2,3])", q=false)            # Returns: "Vector{Int64}"
```

**This is equivalent to automatically adding a semicolon!**

```julia
# These are equivalent:
ex(e="x = 42")        # Automatic semicolon
ex(e="x = 42;")       # Manual semicolon
ex(e="x = 42", q=true)  # Explicit quiet mode
```

### 📦 Combine Multiple Operations

```julia
# ❌ INEFFICIENT - 3 separate calls
ex(e="x = 10")
ex(e="y = 20")
ex(e="z = 30")

# ✅ EFFICIENT - One call, minimal output (quiet mode handles semicolons)
ex(e="x = 10; y = 20; z = 30")
```

### 🧪 Testing Best Practices

```julia
# ✅ Inline test - quiet mode suppresses TestSet object
ex(e="@test my_function(5) == 10")

# ✅ TestSet - quiet mode automatically suppresses return value
ex(e="""
@testset "Feature X" begin
    @test condition1
    @test condition2
end
""")

# ✅ To see test results summary, use verbose mode:
ex(e="@testset \"Tests\" begin @test 1==1 end", q=false)
```

### 🔍 Avoid Displaying Large Data

```julia
# ✅ EFFICIENT - Quiet mode suppresses large output automatically
ex(e="collect(1:1000)")

# ✅ Get summary info when needed
ex(e="result = big_computation(); (length(result), typeof(result))", q=false)

# ✅ For large data, just compute without returning
ex(e="result = expensive_computation()")  # Stores in workspace, doesn't display
```

### 🧹 Use `let` Blocks for Temporary Work

```julia
# ✅ Keeps workspace clean, prints result without returning
ex(e="""
let x = load_data(), y = process(x)
    result = analyze(y)
    println("Result: ", result)
end
""")
```

## Common Workflows

### Loading Packages

```julia
# Load package (quiet mode = no output)
ex(e="using DataFrames")

# Check what's available (need output, so q=false)
ex(e="names(DataFrames)", q=false)
```

### Quick Documentation Lookup

```julia
# Get function documentation (needs output)
ex(e="@doc sort", q=false)

# See all methods (needs output)
ex(e="methods(sort)", q=false)

# Find which method will be called (needs output)
ex(e="@which sort([1,2,3])", q=false)
```

### Debugging Type Issues

```julia
# Check type (needs output)
ex(e="typeof(my_var)", q=false)

# Inspect fields (needs output)
ex(e="fieldnames(typeof(my_var))", q=false)

# Check type hierarchy (needs output)
ex(e="supertype(MyType)", q=false)
```

### Running Code After Edits

```julia
# After editing a file, test changes (quiet mode = just pass/fail output)
ex(e="""
# Revise.jl should auto-reload changes
@test my_updated_function(10) == 20
""")
```

## Error Handling

```julia
# Errors are always returned regardless of quiet mode
ex(e="1/0")
# Returns: "ERROR: DivideByZero..."

# Catch and handle errors (quiet mode suppresses return, shows println)
ex(e="""
try
    risky_operation()
    println("Success")
catch e
    println("Failed: ", e)
end
""")
```

## What NOT to Do

```julia
# ❌ Don't use verbose mode unnecessarily
ex(e="x = 42", q=false)  # Wasteful! Default quiet mode is fine

# ❌ Don't use println to communicate with the user
# (The user sees output in real-time in their REPL already)
ex(e='println("Starting computation...")')

# ❌ Don't change environments
ex(e="Pkg.activate(\".\")")  # Never do this!
```

## Understanding the Parameters

### `q` (quiet) - Default: true
- **Purpose**: Suppress return values to save tokens
- **When to use q=true** (default): When executing code for side effects (assignments, tests, imports)
- **When to use q=false**: When you need to see the computed result

### `s` (silent) - Default: false
- **Purpose**: Suppress the "agent>" prompt and real-time output display
- **Rarely needed**: Only use when output is purely for logging/debugging

## Pro Tips

1. **Trust quiet mode** - The default (q=true) saves 70-90% of tokens
2. **Use q=false sparingly** - Only when you actually need the return value
3. **Combine operations** - Fewer tool calls = better performance
4. **Use `let` blocks** - Keep workspace clean
5. **Trust Revise** - File changes are picked up automatically
6. **Errors always show** - Quiet mode doesn't suppress errors
