# Julia REPL Workflow

This prompt teaches AI agents the proper workflow for Julia development using the exec_repl tool, emphasizing respectful shared REPL usage and best practices.

## Core Principles

### 🤝 Shared REPL Etiquette
- The REPL is shared with the user in real-time
- Be respectful of the workspace and minimize clutter
- Clean up variables the user doesn't need
- Ask before long-running operations (>5 seconds)

### 🔄 Revise.jl Integration
- Changes to Julia functions in `src/` are automatically picked up
- **Exception**: Struct and constant redefinitions require REPL restart
- Always ask the user to restart REPL for struct/constant changes
- Code defined in the `src/` folder of a package should never be directly included, use `using` or `import` to load the package and have Revise take care of the rest.

## Best Practices ✅

### Variable Management
Use `let` blocks for temporary computations:

```julia
let x = 10, y = 20
    result = x + y
    println("Result: $result")
end
```

### Testing Approach
**AVOID** `Pkg.test()` (too slow). Use targeted approaches:

```julia
# 1. Specific test sets
@testset "My Feature Tests" begin
    @test my_function(1) == 2
    @test my_function(0) == 1
end

# 2. Quick inline tests
@test my_function(5) == 6
@test_throws ArgumentError my_function(-1)

# 3. Interactive testing
let test_input = [1, 2, 3]
    result = my_function(test_input)
    @show result
end
```

### MWE Creation
If you have a more complex problem to solve or are unsure about the correct API,
you may want to quickly execute mini-examples in the REPL to investigate the correct
usage of the functions.

### Documentation
Always check documentation before using unfamiliar functions:

```julia
@doc function_name
@doc String            # Type documentation
@doc PackageName.func  # Package function
names(PackageName)     # List package contents

# Method inspection
@which sort([1,2,3])
methods(sort)
methodswith(String)
```

## Environment Management
Check environment without modifying it:

```julia
using Pkg
Pkg.status()
VERSION
versioninfo()
```

When a required package is not available:

1. **Check current environment** with `Pkg.status()`
2. **Stop execution** - don't attempt to install
3. **Contact the operator** with specific requirements:
   ```
   "I need the following packages to complete this task:
   - PackageName1 (for feature X)
   - PackageName2 (for feature Y)

   Please prepare an environment with these dependencies."
   ```
4. **Wait for operator** to set up proper environment

## What NOT TO DO ❌

### 🚫 Environment Modification
Environment is read-only:

```julia
Pkg.activate(".")      # ❌ NEVER (use: # overwrite no-activate-rule)
Pkg.add("PackageName") # ❌ NEVER
Pkg.test()             # ❌ Usually too slow - ask permission first
```

### 🚫 Workspace Pollution
```julia
# Bad - clutters global scope
x = 10; y = 20; z = x + y

# Good - use let blocks
let x = 10, y = 20
    z = x + y
    println(z)
end
```

### 🚫 Including Whole Files
```julia
include("src/myfile.jl")   # ❌ Prefer specific blocks
include("test/tests.jl")   # ❌ Prefer specific testsets
```

### 🚫 Struct/Constant Redefinition
Ask user for REPL restart first:

```julia
struct MyStruct        # ❌ Requires restart
    field::Int
end
```

## Development Cycle
1. **Edit** source files in `src/`
2. **Test** changes with specific function calls
3. **Verify** with `@doc` and `@which`
4. **Run targeted tests** with specific @testset blocks
