# Extended Help: macro_expand

## Overview

The `macro_expand` tool shows what code a Julia macro generates. Macros are code transformations that run at parse time, and understanding their output is essential for:
- Learning how macros work
- Debugging macro-heavy code
- Understanding performance implications
- Writing your own macros

## Basic Usage

```julia
# Syntax: @macroexpand @macroname args...

macro_expand("@time sleep(1)")
macro_expand("@test 1 + 1 == 2")
macro_expand("@inbounds arr[i]")
```

**Note:** Include the `@` symbol in the macro name!

## Common Julia Macros

### @time - Performance Measurement

```julia
# Original code
@time sum(1:1000)

# Expands to (simplified):
```
```julia
let
    local stats = Base.gc_num()
    local elapsedtime = time_ns()
    local val = sum(1:1000)
    elapsedtime = time_ns() - elapsedtime
    local diff = Base.GC_Diff(Base.gc_num(), stats)
    # ... print timing info
    val
end
```

**Key insight:** `@time` wraps your code in timing logic but preserves the return value

### @test - Test Assertions

```julia
# Original code
@test foo(5) == 10

# Expands to (simplified):
```
```julia
let result = foo(5) == 10
    if result
        Test.Pass(:test, ...)
    else
        Test.Fail(:test, ...)
    end
end
```

**Key insight:** `@test` captures both the expression and result for detailed error messages

### @inbounds - Skip Bounds Checking

```julia
# Original code
@inbounds arr[i]

# Expands to:
```
```julia
Base.getindex(arr, i)  # Without bounds check
```

**Key insight:** `@inbounds` removes runtime safety checks for speed (use carefully!)

### @simd - SIMD Optimization Hint

```julia
# Original code
@simd for i in 1:n
    result[i] = arr[i] * 2
end

# Expands to:
```
```julia
for i in 1:n
    Base.@_inline_meta
    Base.@_simd_meta
    result[i] = arr[i] * 2
end
```

**Key insight:** Adds compiler hints for vectorization

### @info, @warn, @error - Logging

```julia
# Original code
@info "Processing" x y

# Expands to:
```
```julia
if Base.CoreLogging.current_logger_for_env(
    Base.CoreLogging.Info, "Processing", Main
) !== nothing
    Base.@logmsg Base.CoreLogging.Info "Processing" x y
end
```

**Key insight:** Logging is conditionally compiled based on log level

## Reading Macro Output

### Understanding Hygiene

Macros generate "hygienic" code to avoid variable name collisions:

```julia
macro twice(x)
    quote
        local temp = $x
        temp + temp
    end
end

# Usage
@twice 5

# Expands to:
```
```julia
let var"#temp#123" = 5  # Unique name!
    var"#temp#123" + var"#temp#123"
end
```

**Hygienic names** look like `var"#name#123"` - these prevent conflicts with your code.

### Quote Blocks

Macros often use `quote ... end` blocks:

```julia
macro mylog(expr)
    quote
        println("Executing: ", $(string(expr)))
        result = $expr
        println("Result: ", result)
        result
    end
end
```

- `quote ... end` = code template
- `$variable` = interpolate value into code
- `$(expression)` = evaluate and interpolate

### Escaping

```julia
macro setvar(name, val)
    quote
        $(esc(name)) = $(esc(val))
    end
end

# Expands to use variables from calling scope
```

`esc()` = escape hygiene, use caller's scope

## Debugging with Macro Expansion

### Example: Understanding @testset

```julia
# Your code
@testset "My tests" begin
    @test 1 == 1
    @test 2 == 2
end

# Expand to see structure
macro_expand("@testset \"My tests\" begin @test 1 == 1 end")
```

**What you'll learn:**
- How test results are collected
- Why tests can be nested
- How @testset creates scope

### Example: Custom Macro Not Working

```julia
macro double(x)
    quote
        $x * 2
    end
end

y = 5
@double y  # Works

@double 2 + 3  # Surprising result?
```

Expand to see why:
```julia
macro_expand("@double 2 + 3")
# Shows: (2 + 3) * 2 = 10  (not 2 + (3 * 2) = 8)
```

**Fix:** Add parentheses in macro:
```julia
macro double(x)
    quote
        ($x) * 2
    end
end
```

## Performance Implications

### Example: Allocation in Loops

```julia
# This macro allocates
macro allocating()
    quote
        [1, 2, 3]
    end
end

for i in 1:1000
    @allocating  # Creates array each iteration!
end
```

Expansion shows the allocation:
```julia
for i in 1:1000
    [1, 2, 3]  # New array every time
end
```

### Example: Type Instability

```julia
macro maybe_int_or_string(flag)
    quote
        if $flag
            1
        else
            "hello"
        end
    end
end
```

Expansion reveals type instability:
```julia
if flag
    1
else
    "hello"
end
# Type: Union{Int, String}
```

## Common Patterns

### 1. Code Generation

```julia
@generated function myfunction(x)
    if x <: Number
        return :(x * 2)
    else
        return :(string(x))
    end
end
```

`@generated` creates specialized code per type.

### 2. Domain-Specific Languages

```julia
# Example: DataFrames @transform
@transform df begin
    :new_col = :old_col * 2
end

# Expands to something like:
transform(df, :old_col => (x -> x * 2) => :new_col)
```

### 3. Expression Manipulation

```julia
macro show_expr(ex)
    quote
        println("Expression: ", $(QuoteNode(ex)))
        println("Eval result: ", $ex)
    end
end
```

## Advanced Techniques

### MacroTools.jl

For complex macro analysis:

```julia
using MacroTools

# Pattern matching on macro output
@macroexpand @time sleep(1) |> MacroTools.prettify
```

### Multiple Expansion Levels

```julia
# If macro calls another macro
@outer @inner x

# Expand once
@macroexpand @outer @inner x

# Expand fully (all levels)
@macroexpand @macroexpand @outer @inner x
```

### Macro Debugging Workflow

```julia
# 1. Start with simple case
@macroexpand @myma cro 1

# 2. Add complexity
@macroexpand @mymacro 1 + 2

# 3. Check with variables
x = 5
@macroexpand @mymacro x

# 4. Check with expressions
@macroexpand @mymacro begin a; b; c end
```

## Complete Example

### Problem: Understanding @benchmark

```julia
using BenchmarkTools

@benchmark sin(0.5)
```

**Question:** What does this macro actually do?

```julia
macro_expand("@benchmark sin(0.5)")
```

**Reveals:**
- Multiple runs for statistical significance
- Compilation run first (not timed)
- Memory allocation tracking
- GC statistics collection
- Outlier detection

**Insight:** This is why `@benchmark` is more accurate than `@time`!

## Troubleshooting

### "Syntax error in expansion"

The macro input might be invalid:
```julia
# ❌ Wrong
macro_expand("@time")  # Missing expression

# ✅ Right
macro_expand("@time sleep(1)")
```

### "Macro not found"

Make sure package is loaded:
```julia
# ❌ Wrong
macro_expand("@test 1 == 1")  # Test not loaded

# ✅ Right
exec_repl("using Test")
macro_expand("@test 1 == 1")
```

### Output Too Complex

Simplify the input:
```julia
# Instead of:
@macroexpand @testset "Tests" begin
    @test a
    @test b
    @test c
end

# Try:
@macroexpand @testset "Tests" begin
    @test a
end
```

### Hygiene Confusion

Use `@macroexpand-1` for one level:
```julia
# Expand only outer macro
Base.macroexpand(Main, :(@outer @inner x), recursive=false)
```

## Best Practices

1. **Start simple** - Expand basic cases first
2. **Check hygiene** - Look for `var"#name#123"` patterns
3. **Understand scope** - See what variables are captured
4. **Check performance** - Look for hidden allocations
5. **Document your macros** - Show expansion in docstrings

## Common Macros to Explore

### Standard Library

```julia
@time        # Timing
@elapsed     # Just the time
@allocated   # Just memory
@assert      # Runtime assertion
@inline      # Inlining hint
@noinline    # Prevent inlining
@view        # Array views
@.           # Broadcast fusion
```

### Testing

```julia
@test        # Basic test
@testset     # Test grouping
@test_throws # Exception testing
@test_skip   # Skip test
```

### Performance

```julia
@inbounds    # Skip bounds check
@simd        # SIMD hint
@fastmath    # Fast math
@threads     # Threading
```

## Writing Your Own Macros

After understanding expansions, you can write macros:

```julia
# Simple logging macro
macro log_call(func_expr)
    quote
        println("Calling: ", $(string(func_expr)))
        local result = $func_expr
        println("Returned: ", result)
        result
    end
end

# Test it
macro_expand("@log_call sin(0.5)")
```

## Quick Reference

```julia
# Basic expansion
macro_expand("@macro_name args")

# In Julia REPL directly
@macroexpand @macro_name args

# One level only
Base.@macroexpand-1 @macro_name args

# From string (via Meta.parse)
eval(Meta.parse("@macroexpand @time sleep(1)"))

# Check if macro exists
isdefined(Main, Symbol("@mymacro"))

# List all macros in module
filter(x -> startswith(string(x), "@"), names(Base, all=true))
```

## Related Tools

- `@macroexpand` - Same as macro_expand, but in Julia syntax
- `@macroexpand-1` - Expand only one level
- `Meta.parse` - Parse code string
- `dump` - Show expression structure
- `MacroTools.jl` - Advanced macro manipulation
