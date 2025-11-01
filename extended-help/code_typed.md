# Extended Help: code_typed

## Overview

The `code_typed` tool shows Julia's type-inferred intermediate representation of a function. This is crucial for understanding performance because **type instability** is the #1 cause of slow Julia code.

## What You'll See

`code_typed` shows:
- Type-inferred Julia IR (intermediate representation)
- Inferred types for every variable
- Control flow structure
- Return type

## Basic Usage

```julia
# Syntax: code_typed(function_name, (ArgType1, ArgType2, ...))

code_typed(sin, (Float64,))
code_typed(+, (Int, Int))
code_typed(my_function, (String, Vector{Int}))
```

## Reading the Output

### Example: Type-Stable Function

```julia
function add_numbers(x::Int, y::Int)
    return x + y
end

code_typed(add_numbers, (Int, Int))
```

Output will look like:
```
CodeInfo(
1 ─ %1 = Base.add_int(x, y)::Int64
└──      return %1
) => Int64
```

**What this means:**
- `%1` = temporary variable
- `Base.add_int(x, y)::Int64` = function call with type annotation
- `::Int64` = **the type is known!** ✅
- `=> Int64` = return type is Int64

### Example: Type-Unstable Function

```julia
function bad_function(flag)
    if flag
        return 1
    else
        return "hello"
    end
end

code_typed(bad_function, (Bool,))
```

Output:
```
CodeInfo(
1 ─ %1 = (flag)::Bool
└──      goto #3 if not %1
2 ─      return 1
3 ─      return "hello"
) => Union{Int64, String}
```

**Red flags:**
- `=> Union{Int64, String}` = return type is unstable ❌
- Multiple possible return types = compiler can't optimize

## Spotting Type Instability

### 🚨 Warning Signs

Look for these patterns in the output:

**1. Union types (except Union{T, Nothing})**
```
=> Union{Int64, String}        # ❌ BAD
=> Union{Float64, Int64}       # ❌ BAD
=> Union{Vector, Nothing}      # ✅ OK (common pattern)
```

**2. Any types**
```
%5 = x::Any                    # ❌ VERY BAD
return %1::Any                 # ❌ VERY BAD
```

**3. Abstract types**
```
%3 = result::AbstractVector    # ⚠️  Could be better
%2 = value::Real               # ⚠️  Could be better
```

**4. Dynamic dispatch**
```
invoke MethodInstance for f(::Any)  # ❌ Dynamic dispatch
```

### ✅ Good Patterns

**Concrete types:**
```
%1 = x::Int64                  # ✅ GOOD
%2 = result::Vector{Float64}   # ✅ GOOD
%3 = flag::Bool                # ✅ GOOD
```

**Type parameters preserved:**
```
%1 = x::Vector{T}              # ✅ GOOD (where T is from function signature)
```

## Common Type Instability Causes

### 1. Uninitialized Variables

```julia
# ❌ BAD - type changes
function sum_bad(n)
    total = 0  # Int
    for i in 1:n
        total += sqrt(i)  # Now Float64!
    end
    return total
end

# ✅ GOOD - consistent type
function sum_good(n)
    total = 0.0  # Float64 from start
    for i in 1:n
        total += sqrt(i)
    end
    return total
end
```

### 2. Conditional Return Types

```julia
# ❌ BAD - different return types
function process(x)
    if x > 0
        return x
    else
        return nothing
    end
end

# ✅ GOOD - consistent return type
function process(x)
    if x > 0
        return Some(x)
    else
        return nothing
    end
end
# Returns Union{Some{Int}, Nothing} - this is OK!
```

### 3. Global Variables

```julia
GLOBAL_VAR = 1

# ❌ BAD - global type can change
function use_global()
    return GLOBAL_VAR + 1
end

# ✅ GOOD - pass as argument
function use_param(var)
    return var + 1
end
```

### 4. Containers Without Type Parameters

```julia
# ❌ BAD - element type unknown
function process_array(arr)
    result = []  # Vector{Any}
    for x in arr
        push!(result, x * 2)
    end
    return result
end

# ✅ GOOD - specify element type
function process_array(arr::Vector{T}) where T
    result = T[]  # Vector{T}
    for x in arr
        push!(result, x * 2)
    end
    return result
end
```

## Complete Example Workflow

### Step 1: Suspect Performance Issue

```julia
function slow_sum(n)
    total = 0
    for i in 1:n
        total += sqrt(i)
    end
    return total
end
```

### Step 2: Check Type Inference

```julia
code_typed(slow_sum, (Int,))
```

Output shows:
```
%5 = (total = Base.add_float(total, %4))::Float64
%6 = (total = Core.typeassert(%5, Base.Int))::Int64
```

**Problem identified:** `total` switches between Float64 and Int64!

### Step 3: Fix the Issue

```julia
function fast_sum(n)
    total = 0.0  # Start as Float64
    for i in 1:n
        total += sqrt(i)
    end
    return total
end
```

### Step 4: Verify Fix

```julia
code_typed(fast_sum, (Int,))
```

Now shows consistent `::Float64` everywhere ✅

## Advanced Tips

### Type Parameters

```julia
# Generic function preserves type info
function double(x::T) where T
    return x + x
end

code_typed(double, (Int,))     # Returns Int64
code_typed(double, (Float64,)) # Returns Float64
```

### Multiple Methods

```julia
# Check which method gets called
methods(my_function)

# Check specific method
code_typed(my_function, (Int, String))
```

### Compare with @code_warntype

```julia
# More user-friendly warnings
@code_warntype my_function(args)

# Same as
code_typed(my_function, (typeof(arg1), typeof(arg2)))
```

## Performance Impact

**Type-stable code:**
- Compiler generates efficient machine code
- No runtime type checks
- Fully optimizable

**Type-unstable code:**
- Runtime type checks on every operation
- Dynamic dispatch (slow!)
- 10-100x slower than type-stable equivalent

## Troubleshooting

### "No methods matching"

```julia
# ❌ Wrong argument types
code_typed(sort, (Int,))  # sort doesn't take Int

# ✅ Correct argument types
code_typed(sort, (Vector{Int},))
```

### Output Too Complex

```julia
# Simplify the function
# Check one piece at a time

function complex_function(x)
    a = step1(x)
    b = step2(a)
    return step3(b)
end

# Check each step
code_typed(step1, (typeof(x),))
code_typed(step2, (typeof(a),))
code_typed(step3, (typeof(b),))
```

### Abstract Types Everywhere

```julia
# Function barrier pattern
function outer(x)
    # x might be abstract type
    inner(x)  # Compiler specializes here
end

function inner(x::T) where T
    # T is concrete here
    # Fast code
end
```

## Best Practices

1. **Always check critical functions** - Use `code_typed` on performance-critical code
2. **Look for Any and Union** - These are the biggest red flags
3. **Fix type instabilities first** - Before micro-optimizations
4. **Use type annotations strategically** - For function arguments and fields
5. **Test with realistic types** - Use actual types from your use case

## Related Tools

- `@code_warntype` - Higher-level, highlights type issues in color
- `code_lowered` - Shows pre-inference IR
- `@code_llvm` - Shows LLVM IR (lower level)
- `@code_native` - Shows assembly (lowest level)

## Quick Reference

```julia
# Basic check
code_typed(my_func, (ArgType1, ArgType2))

# Multiple return values (look at last one)
results = code_typed(my_func, (Int,))
results[1]  # First method match

# Return type only
code_typed(my_func, (Int,))[1].second  # => Int64

# Check if type-stable (programmatically)
function is_type_stable(f, types)
    ci = code_typed(f, types)[1]
    rettype = ci.second
    return isconcretetype(rettype) || rettype === Nothing
end
```
