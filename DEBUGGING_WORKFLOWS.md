# AI Agent Debugging Workflows

This document demonstrates how AI agents can use the MCPRepl debugging tools to autonomously investigate and fix issues.

## Available Debugging Tools (25 Total MCP Tools)

### Core Debugging Flow
- `open_file_and_set_breakpoint(file_path, line)` - Set breakpoint at specific location
- `start_debug_session()` - Start debugging
- `debug_step_over()` - Execute current line, stay at same level
- `debug_step_into()` - Enter function call
- `debug_step_out()` - Return to caller
- `debug_continue()` - Run until next breakpoint
- `debug_stop()` - Terminate debug session

### Inspection
- `add_watch_expression(expression)` - Monitor expression value
- `copy_debug_value(view)` - Copy variable to clipboard (legacy)
- Future: `get_debug_variable(name)` - Direct variable access via bidirectional communication

### Package Management
- `pkg_add(packages)` - Add dependencies
- `pkg_rm(packages)` - Remove packages

## Workflow Examples

### Workflow 1: Test Failure Investigation

**Scenario**: A test is failing with unexpected output.

```julia
# 1. Agent sees test failure
julia> @testset "MyFeature" begin
           @test my_function(5) == 10  # FAILS: got 15 instead
       end

# 2. Agent investigates by setting breakpoint
open_file_and_set_breakpoint("/path/to/src/mymodule.jl", 42)

# 3. Start debug session and run the test
start_debug_session()
# In debug console or REPL: run the test again

# 4. When stopped at breakpoint, step through
debug_step_over()  # Execute line 42
debug_step_over()  # Execute line 43

# 5. Add watch for suspicious variables
add_watch_expression("intermediate_value")
add_watch_expression("multiplier")

# 6. Continue stepping and observe values change
debug_step_over()
# Look at VS Code Variables panel - see multiplier = 3 instead of 2

# 7. Agent identifies the bug: multiplier is wrong
# Agent fixes code: multiplier = 2 instead of 3

# 8. Stop debugging and test again
debug_stop()
```

**Agent Monologue**:
```
"The test expects 10 but got 15. That's 1.5x the input, suggesting a multiplier issue.
Let me set a breakpoint at the calculation and step through...
Ah! The multiplier variable is 3 when it should be 2. I'll fix that."
```

### Workflow 2: Understanding Complex Control Flow

**Scenario**: User asks "Why does this function return early sometimes?"

```julia
# 1. Agent sets breakpoints at all return statements
open_file_and_set_breakpoint("/path/to/src/complex.jl", 15)  # early return 1
open_file_and_set_breakpoint("/path/to/src/complex.jl", 23)  # early return 2
open_file_and_set_breakpoint("/path/to/src/complex.jl", 45)  # normal return

# 2. Start debug and trigger the function
start_debug_session()
# Run: complex_function(test_input)

# 3. Hits breakpoint at line 15
add_watch_expression("condition_a")
add_watch_expression("state.status")
debug_step_over()

# 4. Observe: condition_a = true because state.status = :pending
# Agent now understands: "It returns early when status is :pending"

debug_continue()  # Test with different input
```

**Agent Output**:
```
"The function returns early at line 15 when state.status == :pending.
This happens because the initialization step was skipped. 
You need to call init_state() before calling complex_function()."
```

### Workflow 3: Performance Debugging

**Scenario**: Function is slow, profiling shows hotspot.

```julia
# 1. Agent profiles code
profile_code("""
    for i in 1:100
        slow_function(data)
    end
""")
# Output shows 90% time in line 67

# 2. Set breakpoint at the hotspot
open_file_and_set_breakpoint("/path/to/src/slow.jl", 67)

# 3. Debug and inspect
start_debug_session()
# Run: slow_function(test_data)

# 4. When stopped, check variable sizes
add_watch_expression("sizeof(temp_array)")
add_watch_expression("length(temp_array)")
debug_step_over()

# 5. Agent sees: temp_array is allocating 1GB every iteration!
# Agent identifies: "This creates a huge temporary array in a loop"
# Agent suggests: "Pre-allocate outside the loop or use views"

debug_stop()
```

### Workflow 4: Conditional Breakpoint Logic

**Scenario**: Bug only happens with specific input values.

```julia
# 1. User reports: "Fails when x > 100"
# Agent sets breakpoint and adds watch
open_file_and_set_breakpoint("/path/to/src/buggy.jl", 30)
start_debug_session()

# 2. Run with small input first
# Run: buggy_function(50)
# Execution hits breakpoint
add_watch_expression("x")
add_watch_expression("x > 100")
debug_continue()  # Skip this iteration

# 3. Run with large input
# Run: buggy_function(150)
# Hits breakpoint, x = 150
debug_step_into()  # Enter the conditional branch
# Now inside the problematic code path
debug_step_over()
debug_step_over()
# Agent observes the exact line where it fails

debug_stop()
```

### Workflow 5: Integration Test Debugging

**Scenario**: Integration test fails, need to trace through multiple modules.

```julia
# 1. Set breakpoints at module boundaries
open_file_and_set_breakpoint("/path/to/module_a.jl", 20)
open_file_and_set_breakpoint("/path/to/module_b.jl", 45)
open_file_and_set_breakpoint("/path/to/module_c.jl", 12)

# 2. Start debug and run integration test
start_debug_session()
# Run integration test

# 3. Hit first breakpoint in module_a
add_watch_expression("request_data")
debug_step_over()
debug_continue()  # Move to next module

# 4. Hit breakpoint in module_b
add_watch_expression("processed_data")
# Agent notices: "Wait, processed_data is missing a field!"
# Agent steps back through call stack
debug_step_into()  # Go deeper to see where field was lost

# 5. Agent identifies: "Module A's output doesn't match Module B's expected input"
# Agent suggests: "Add the missing field to the data structure in Module A"

debug_stop()
```

## Advanced Patterns

### Pattern 1: Comparative Debugging

Compare behavior between working and broken cases:

```julia
# Test 1: Working case
open_file_and_set_breakpoint("src/func.jl", 10)
start_debug_session()
# Run: func(good_input)
add_watch_expression("intermediate")
# Note: intermediate = 42
debug_stop()

# Test 2: Broken case
start_debug_session()
# Run: func(bad_input)
# Note: intermediate = nil (should be 42!)
# Agent identifies: input validation missing
debug_stop()
```

### Pattern 2: Recursive Debugging

Step through recursive calls:

```julia
open_file_and_set_breakpoint("src/recursive.jl", 5)
start_debug_session()
# Run: recursive_func(10)

# At each recursive call:
add_watch_expression("n")
add_watch_expression("accumulator")
debug_step_into()  # Go into next recursive call
# Observe stack depth and variable changes
debug_step_out()  # When done, return to caller
```

### Pattern 3: State Machine Debugging

Track state transitions:

```julia
open_file_and_set_breakpoint("src/state_machine.jl", 30)
start_debug_session()

add_watch_expression("current_state")
add_watch_expression("event")
add_watch_expression("next_state")

# Step through each state transition
debug_step_over()  # Trigger transition
# Observe: current_state = :init, event = :start, next_state = :running
debug_step_over()
# Observe: current_state = :running, event = :data, next_state = :running
debug_step_over()
# Observe: current_state = :running, event = :error, next_state = :error

# Agent maps out the state machine behavior
debug_stop()
```

## Benefits for AI Agents

### Autonomous Investigation
Instead of asking the user "Can you check what value X has?", agents can:
1. Set breakpoint
2. Run code
3. Inspect values
4. Identify issue
5. Suggest fix with evidence

### Faster Iteration
Traditional: "I think the bug is in line 50... wait, need more info... can you run this?"
With debugging: "Let me step through... yes, confirmed, line 50, here's the exact value that's wrong"

### Learning Code Behavior
Agents can explore unfamiliar codebases by:
1. Setting breakpoints at interesting functions
2. Running examples
3. Observing actual runtime behavior
4. Building mental model of how code works

### Verifying Fixes
After suggesting a fix:
1. Apply the change
2. Debug through the same scenario
3. Confirm the fix works
4. Report: "Verified: variable now has correct value"

## Limitations & Future Work

### Current Limitations
- **Cannot directly read variable values yet** - Still need clipboard or watch expressions
- **Cannot set conditional breakpoints programmatically** - Need VS Code UI
- **Limited call stack inspection** - Cannot programmatically navigate stack frames

### Future Enhancements
With full bidirectional communication:
- `get_debug_variable(name)` → Returns variable value directly
- `get_call_stack()` → Returns array of stack frames
- `get_all_local_variables()` → Returns dict of all locals
- `evaluate_in_debug_context(expr)` → Evaluate arbitrary expression
- `set_conditional_breakpoint(file, line, condition)` → Smart breakpoints

### Proposed API
```julia
# Future: Direct variable access
variables = get_all_local_variables()
# Returns: Dict("x" => 42, "y" => "hello", "arr" => [1,2,3])

value = get_debug_variable("complex_struct")
# Returns: ComplexStruct with full field values

stack = get_call_stack()
# Returns: [
#   Dict("function" => "inner", "file" => "a.jl", "line" => 10),
#   Dict("function" => "outer", "file" => "b.jl", "line" => 25),
# ]

result = evaluate_in_debug_context("x + y * 2")
# Returns: 84 (if x=42, y=21)
```

## Best Practices for AI Agents

1. **Always explain what you're doing**: "Setting breakpoint to inspect..."
2. **Clean up after debugging**: Call `debug_stop()` when done
3. **Remove breakpoints**: Users don't want leftover breakpoints
4. **Use watch expressions liberally**: Better than stepping blindly
5. **Combine with profiling**: Profile first to find hotspots, then debug
6. **Document findings**: Show evidence from debug session
7. **Verify fixes**: Re-run debug session to confirm fix works

## Example: Complete Debugging Session

```julia
# User: "Test test_parse_data is failing"

# Agent investigates:
"""
Let me debug this test to see what's happening:

1. Setting breakpoint at the parse_data function
"""
open_file_and_set_breakpoint("src/parser.jl", 15)

"""
2. Starting debug session
"""
start_debug_session()

"""
3. Now I'll run the failing test and observe what happens...
   [Running test in debug mode]
   
4. Execution stopped at line 15. Let me check the input:
"""
add_watch_expression("raw_data")
add_watch_expression("expected_format")

"""
5. Stepping through the parsing logic:
"""
debug_step_over()  # Line 16
debug_step_over()  # Line 17
add_watch_expression("parsed_result")

"""
6. I can see the issue! The parsed_result is missing the 'timestamp' field.
   Looking at line 17, the regex pattern doesn't capture the timestamp.
   
7. Stopping debug session
"""
debug_stop()

"""
Here's the fix needed:
Line 17 should be:
    pattern = r"(\d+):(.+):(\d{10})"  # Added timestamp group
Instead of:
    pattern = r"(\d+):(.+)"  # Missing timestamp

The test fails because the timestamp field is required but not being parsed.
I've verified this by stepping through the code and inspecting the variables.
"""
```

This is how autonomous debugging looks in practice!
