# Debugging Demo: Using MCPRepl Tools

This document demonstrates how to use MCPRepl's MCP tools to create, test, debug, and fix Julia code.

## Overview

Created a new statistics utility module (`StatsUtils.jl`) with intentional bugs, then used MCP tools to diagnose and fix them.

## MCP Tools Used

### 1. **Code Execution** - `ex` tool
Used to load, test, and verify the module interactively:

```julia
# Load the module
ex(e="include('/path/to/StatsUtils.jl')")

# Test functions
ex(e="mean([1,2,3,4,5])", q=false)
ex(e="moving_average([1,2,3,4,5], 3)", q=false)
```

**Why it's useful:** Immediate feedback in the shared REPL, visible to both human and agent.

### 2. **File Reading** - `Read` tool
Used to inspect specific sections of the code:

```julia
Read(file_path="/path/to/StatsUtils.jl", offset=68, limit=25)
```

**Why it's useful:** Targeted code inspection with line numbers for precise debugging.

### 3. **LSP Tools** - `lsp_document_symbols`
Used to get an overview of the module structure:

```julia
lsp_document_symbols(file_path="/path/to/StatsUtils.jl")
```

**Why it's useful:** Quick navigation to understand code organization.

### 4. **File Editing** - `Edit` tool
Used to fix the bugs once identified:

```julia
Edit(
    file_path="/path/to/StatsUtils.jl",
    old_string="for i in 1:(length(data) - window)",
    new_string="for i in 1:(length(data) - window + 1)"
)
```

**Why it's useful:** Precise, surgical fixes with exact string replacement.

### 5. **Todo Tracking** - `TodoWrite` tool
Used to track progress through the debugging workflow:

```julia
TodoWrite(todos=[
    {content: "Fix moving_average", status: "in_progress"},
    {content: "Fix variance", status: "pending"}
])
```

**Why it's useful:** Maintains focus and tracks multiple bugs systematically.

## Bugs Found and Fixed

### Bug #1: Moving Average Off-by-One Error

**Location:** Line 80

**Symptom:**
- Expected 3 values for window=3, data length=5
- Got only 2 values

**Diagnosis Process:**
1. Ran `moving_average([1,2,3,4,5], 3)` → got `[2.0, 3.0]`
2. Calculated expected: `length(data) - window + 1 = 5 - 3 + 1 = 3`
3. Inspected code with `Read` tool
4. Found loop: `for i in 1:(length(data) - window)` → only goes to 2!

**Fix:**
```julia
# Before
for i in 1:(length(data) - window)

# After
for i in 1:(length(data) - window + 1)
```

**Verification:**
```julia
moving_average([1,2,3,4,5], 3) == [2.0, 3.0, 4.0] ✓
```

### Bug #2: Variance Using Population Formula

**Location:** Line 32

**Symptom:**
- Calculating population variance (divide by n)
- Users typically expect sample variance (divide by n-1)

**Diagnosis Process:**
1. Calculated variance: `variance([1,2,3,4,5])` → got `2.0`
2. Compared to Julia's stdlib: `var([1,2,3,4,5])` → expected `2.5`
3. Realized we're dividing by `n` instead of `n-1`

**Fix:**
```julia
# Before
return sum((x - m)^2 for x in data) / length(data)

# After
if length(data) == 1
    return 0.0
end
return sum((x - m)^2 for x in data) / (length(data) - 1)
```

**Verification:**
```julia
variance([1,2,3,4,5]) ≈ 2.5 ✓
variance([1.0]) == 0.0 ✓  # Edge case
```

## Testing Workflow

Created comprehensive test suite using the REPL:

```julia
@testset "StatsUtils Fixed Tests" begin
    @testset "Mean" begin
        @test mean([1, 2, 3, 4, 5]) == 3.0
        @test mean([10.0]) == 10.0
        @test_throws ArgumentError mean(Int[])
    end

    @testset "Moving Average - THE FIX!" begin
        result = moving_average([1, 2, 3, 4, 5], 3)
        @test result == [2.0, 3.0, 4.0]
        @test length(result) == 3  # Was 2 before!
    end
    # ... more tests
end
```

**Result:** ✅ 16/16 tests passing

## Key Takeaways

1. **Interactive Testing** - The `ex` tool allows immediate verification
2. **Targeted Inspection** - `Read` tool shows exact line numbers
3. **Precise Fixes** - `Edit` tool makes surgical changes
4. **Progress Tracking** - `TodoWrite` keeps debugging organized
5. **Comprehensive Verification** - Test suites confirm fixes work

## MCP Tools Workflow Summary

```
1. Write code → Use Write tool
2. Load module → Use ex tool
3. Test functions → Use ex tool with q=false
4. Find bugs → Compare expected vs actual output
5. Inspect code → Use Read tool or lsp_document_symbols
6. Track fixes → Use TodoWrite tool
7. Fix bugs → Use Edit tool
8. Verify fixes → Use ex tool with @testset
9. Document → Use Write tool
```

This demonstrates the power of MCPRepl for collaborative, REPL-driven development with AI assistance!
