# Julia REPL Workflow

This prompt teaches AI agents the proper workflow for Julia development using the exec_repl tool, emphasizing respectful shared REPL usage and best practices.

## Core Principles

### 🚨 MCP Server Requirement
- **CRITICAL**: Once you read this document, expect the MCP REPL server to exist
- If the `exec_repl` tool is not available, DO NOT silently continue
- This indicates a broken development setup that needs immediate attention
- **Required action**: Stop and ask the user how to handle the situation:
  ```
  "The MCP REPL server appears to be unavailable. The exec_repl tool is required for Julia development.
  Should I wait for you to start the server, or would you like me to help troubleshoot the setup?"
  ```

### 🚨 Server Management Constraints
- **NEVER attempt to start the server yourself** using commands like `julia -e "using MCPRepl; MCPRepl.start!()"`
- **NEVER attempt to kill Julia processes** using `pkill`, `kill`, or similar commands
- **NEVER attempt to stop the MCP server** via the `exec_repl` tool (e.g., `MCPRepl.stop!()`)
- **Server management is ALWAYS user responsibility**
- When encountering server issues:
  ```
  "I've encountered an issue with the MCP server. Server management is your responsibility.
  Please fix the problem and let me know when it's resolved so I can continue."
  ```

### 🤝 Shared REPL Etiquette
- The REPL is shared with the user in real-time
- Be respectful of the workspace and minimize clutter
- Clean up variables the user doesn't need
- Ask before long-running operations (>5 seconds)

### 💬 REPL Communication Protocol
- **CRITICAL**: The REPL is for information gathering ONLY, NOT for user communication
- **All communication with the user MUST happen through the chat interface**
- The user can observe REPL activity, but don't use it as a communication channel
- The REPL returns both stdout and the expression's return value - use these for YOUR analysis
- Print only what YOU need to gather information, not to communicate with the user:
  - ✅ Let expressions return values naturally: `result = compute()` (you receive the value)
  - ✅ Use `@show` or `println()` if YOU need to inspect intermediate values
  - ✅ Use `@doc` to check documentation (you receive the docs)
  - ✅ Run tests that print their results (you receive pass/fail info)
  - ❌ DON'T add `println("Starting computation...")` to narrate to the user
  - ❌ DON'T use `@info "Checking function..."` to update the user on progress
  - ❌ DON'T print explanatory messages like `println("This tests the edge case")`
- After gathering information via REPL, communicate findings through chat
- Example workflow:
  ```
  1. Execute: result = my_function(test_data)  # You receive the return value
  2. Verify: @test result == expected          # You receive test output
  3. Communicate via chat: "The function works correctly, returning [explanation]"
  ```

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

### Environment Investigation
Before starting work, use the `investigate_environment` tool to understand your development setup:

```julia
# This tool provides comprehensive environment information including:
# - Current working directory and active project
# - Development packages tracked by Revise.jl
# - Regular packages in the environment
# - Revise.jl status for hot reloading
```

**Best Practice**: Always call `investigate_environment` at the start of Julia development sessions to understand what packages are available and which ones are in development mode.

### Manual Environment Checks
You can also check environment manually without modifying it:

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
