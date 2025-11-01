# MCPRepl Usage Quiz - Solutions

## Self-Grading Instructions

1. Compare your answers with solutions below
2. Award points based on key concepts captured
3. Partial credit allowed for main ideas
4. Calculate total score out of 100
5. If below 75, review `usage_instructions` and retake

---

## Question 1: Shared REPL Model (10 points)

**Answer:** User and agent work in the same REPL in real-time. Everything you execute appears in their REPL immediately with the same output.

**Key implication:** DO NOT use `println` to communicate. They already see your code execute. Use TEXT responses (outside tool calls) to explain.

**Grading:**
- 10: Explained shared REPL + no println for communication
- 7: Shared REPL mentioned, missed println issue
- 4: Vague understanding, missed communication implication
- 0: Didn't understand shared model

---

## Question 2: Communication Channels (15 points)

**Answer:**
1. **Explain testing:** TEXT response - "Let me test the function:"
2. **Execute test:** `q=true` (default) - `ex(e="result = test_function(data)")`
3. **Show result:** They already see it! Only use `q=false` if YOU need the value for decision-making

**Grading:**
- 15: All correct, ruled out println
- 12: Main channels right, minor q=false confusion
- 8: TEXT vs code understood, q parameter confused
- 4: Major confusion
- 0: Completely wrong (e.g., use println)

---

## Question 3: When to Use `q=false` (20 points)

**Answers:**
- a) `q=true` - no return value needed
- b) `q=true` - don't need to see the value
- c) `q=false` - NEED value to decide (is it 2 or 3?)
- d) `q=true` - don't need to see function object
- e) `q=false` - need to analyze method signatures

**Key:** Only `q=false` when you need the return value for decision-making.

**Grading:** 4 points each (correct answer + reasoning)

---

## Question 4: Critique This Code (25 points)

**Problems:**

1. **Excessive printlns (10 pts)** - User already sees code execute. Use TEXT responses instead.

2. **Unnecessary q=false (10 pts)** - Wastes ~400 tokens. Use `q=true` default for assignments/imports.

3. **No batching (5 pts)** - Four separate calls could be combined.

**Corrected:**
```julia
# TEXT: "Let me load the module and compute the mean:"
ex(e="include('MyModule.jl'); using .MyModule; data = [1,2,3,4,5]; m = mean(data)")
ex(e="m", q=false)  # Only if you need to inspect the value
```

**Grading:**
- 25: All three problems identified
- 20: println + q=false issues found
- 15: Only println issue found
- 10: Vague awareness something's wrong
- 0: Thought code was fine

---

## Question 5: Token Efficiency (15 points)

**Answer:** `q=true` suppresses unnecessary return values, saving **70-90% of tokens**. Matters because:
- Every token counts toward context budget
- More waste = shorter conversations
- Can execute 5-10x more operations in same budget

**Grading:**
- 15: Explained percentage + context impact
- 12: Mentioned savings, weak impact explanation
- 8: Vague understanding
- 4: Knew it's "good" but not why
- 0: No understanding

---

## Question 6: Real-World Scenario (15 points)

**Answer:**
```julia
ex(e="test_data = [1, 2, 3, 4, 5]")              # q=true - no return needed
ex(e="result = moving_average(test_data, 3)")   # q=true - no return needed
ex(e="length(result)", q=false)                  # q=false - NEED value to decide
# Result already stored in step 2 - nothing more needed
```

**Alternative (more efficient):**
```julia
ex(e="test_data = [1,2,3,4,5]; result = moving_average(test_data, 3)")
ex(e="length(result)", q=false)
```

**Grading:**
- 15: Correct q usage with reasoning
- 12: Correct but could be more efficient
- 8: Key idea (q=false for length) but wrong elsewhere
- 4: Some understanding, multiple mistakes
- 0: Used q=false everywhere

---

## Final Assessment

**Total:** _____ / 100

### Score Interpretation

**90-100 - EXCELLENT ✅**
- Strong understanding, ready to work efficiently
- Apply principles consistently

**75-89 - GOOD ✓**
- Core concepts understood
- Review missed areas before starting

**60-74 - REVIEW NEEDED ⚠️**
- Gaps in understanding
- Review `usage_instructions`: Shared REPL Model, q parameter, communication channels
- Retake quiz

**Below 60 - NEEDS STUDY ❌**
- Review `usage_instructions` carefully
- Focus on shared REPL model section and examples
- Must score 75+ before working with users

---

## Report to User

After grading, report:

```
Quiz Results:
- Score: X/100
- Grade: [Excellent/Good/Review Needed/Needs Study]
- Struggled with: [question numbers]
- Self-assessment: [honest evaluation]
- Next steps: [start work / review and retake]
```

Be honest! This helps you work efficiently and save tokens.
