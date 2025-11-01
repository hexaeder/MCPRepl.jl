# MCPRepl Usage Quiz

Test your understanding of the `ex` tool and shared REPL environment. Answer each question, then call `usage_quiz(show_sols=true)` to check answers and grade yourself.

---

## Question 1: Shared REPL Model (10 points)

What does it mean that the user and agent work in a shared REPL, and what's the most important implication for communication?

---

## Question 2: Communication Channels (15 points)

You want to: (1) explain you're testing a function, (2) execute the test, (3) show the result.

Where should each happen? (Options: TEXT response, `q=true`, `q=false`, println)

---

## Question 3: When to Use `q=false` (20 points)

Should you use `q=true` or `q=false` for each? Explain why.

a) `ex(e="using Statistics")`
b) `ex(e="test_data = [1, 2, 3, 4, 5]")`
c) `ex(e="length(result)")` - to check if there's a bug
d) `ex(e="function foo(x) return x^2 end")`
e) `ex(e="methods(my_function)")` - to analyze signatures

---

## Question 4: Critique This Code (25 points)

Identify ALL problems and explain what should be done instead:

```julia
ex(e="println('Loading module...'); include('MyModule.jl')", q=false)
ex(e="println('Creating test data...'); data = [1,2,3,4,5]", q=false)
ex(e="println('Computing mean...'); m = mean(data)", q=false)
ex(e="println('Result is: ', m)", q=false)
```

---

## Question 5: Token Efficiency (15 points)

Why is `q=true` (default) important? Approximately how much does it save, and why does this matter?

---

## Question 6: Real-World Scenario (15 points)

Test a `moving_average` function by: (1) creating test data, (2) calling the function, (3) checking if length is 2 or 3, (4) storing the result.

Write the `ex` calls with correct `q` parameter choices.

---

## Grading Scale

- **90-100**: Excellent! Ready to use MCPRepl effectively.
- **75-89**: Good. Review missed areas before starting.
- **60-74**: Review `usage_instructions` and retake.
- **Below 60**: Study `usage_instructions` carefully and retake.

**Check answers:** `usage_quiz(show_sols=true)`
