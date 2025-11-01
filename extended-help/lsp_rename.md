# Extended Help: lsp_rename

## Overview

The `lsp_rename` tool uses the Julia Language Server to safely rename a symbol (function, variable, type) everywhere it's used in your workspace.

## How to Find the Position

You need to know the exact file, line, and column where the symbol is defined or used.

### Method 1: Use lsp_goto_definition First

```julia
# 1. Find where you're using the symbol
lsp_goto_definition(
    file_path="/path/to/file.jl",
    line=42,
    column=10
)

# 2. Use the returned position for rename
lsp_rename(
    file_path="/path/to/definition.jl",  # From step 1
    line=15,                               # From step 1
    column=5,                              # From step 1
    new_name="better_name"
)
```

### Method 2: Use lsp_document_symbols

```julia
# List all symbols in a file
lsp_document_symbols(file_path="/path/to/file.jl")

# Find the symbol you want, note its line/column
# Then use lsp_rename
```

## Column Number Tips

**Column numbers are 1-indexed and count from the start of the line.**

Example line: `    function calculate_result(x)`
- Column 5: the `f` in `function`
- Column 14: the `c` in `calculate_result`
- Column 32: the `x` in the parameter

**Tip:** Put your cursor on the symbol in VS Code and use `lsp_goto_definition` to get the exact position.

## Understanding the Response

The tool returns a `WorkspaceEdit` description showing all files that will be modified:

```
WorkspaceEdit:
  /path/to/file1.jl:
    - Line 15, Col 5-20: old_name → new_name
    - Line 42, Col 10-25: old_name → new_name

  /path/to/file2.jl:
    - Line 8, Col 15-30: old_name → new_name
```

**Note:** The rename is NOT applied automatically! The LSP returns what WOULD change.

## Common Use Cases

### Renaming a Function

```julia
# File: mymodule.jl, line 10
# function process_data(x)
#     ...
# end

lsp_rename(
    file_path="/path/to/mymodule.jl",
    line=10,
    column=10,  # On "process_data"
    new_name="process_input"
)
```

### Renaming a Variable

```julia
# File: script.jl, line 25
# total = sum(values)

lsp_rename(
    file_path="/path/to/script.jl",
    line=25,
    column=1,  # On "total"
    new_name="total_sum"
)
```

### Renaming a Type

```julia
# File: types.jl, line 5
# struct DataPoint
#     x::Float64
#     y::Float64
# end

lsp_rename(
    file_path="/path/to/types.jl",
    line=5,
    column=8,  # On "DataPoint"
    new_name="Measurement"
)
```

## Complete Workflow Example

```julia
# Goal: Rename function "calc" to "calculate"

# Step 1: Find where calc is defined
definitions = lsp_goto_definition(
    file_path="/path/to/usage.jl",
    line=50,
    column=15
)

# Step 2: Extract the definition location
# (Assume it returns: /path/to/module.jl, line 10, column 10)

# Step 3: Perform the rename
changes = lsp_rename(
    file_path="/path/to/module.jl",
    line=10,
    column=10,
    new_name="calculate"
)

# Step 4: Review the changes (returned in response)
# Step 5: Apply changes manually using Edit tool
```

## Combining with Other LSP Tools

### Find All Uses Before Renaming

```julia
# 1. Find all references first
refs = lsp_find_references(
    file_path="/path/to/file.jl",
    line=42,
    column=10
)

# 2. Review references
# 3. Then rename if appropriate
lsp_rename(
    file_path="/path/to/file.jl",
    line=42,
    column=10,
    new_name="new_name"
)
```

### Check Definition Before Renaming

```julia
# 1. Jump to definition
def = lsp_goto_definition(
    file_path="/path/to/usage.jl",
    line=50,
    column=15
)

# 2. Verify it's the right symbol
# 3. Use the definition location for rename
```

## Troubleshooting

### "Symbol not found"
- Check your line and column numbers are correct
- Ensure you're pointing to a valid symbol (not whitespace or comments)
- Make sure the file is part of the LSP workspace

### "No changes returned"
- Symbol might not be used anywhere else
- LSP might not have indexed the files yet
- Try running code first to ensure LSP is aware of the symbol

### Rename Seems Incomplete
- LSP only renames within its workspace view
- Dynamic/string-based references won't be renamed
- Check if the symbol exists in multiple modules (only renames in scope)

## Best Practices

1. **Always check the position first** - Use `lsp_goto_definition` to find exact location
2. **Review the changes** - WorkspaceEdit shows what will change before applying
3. **Be careful with common names** - Renaming `x` or `i` might affect more than you expect
4. **Check scope** - LSP respects scoping rules, won't rename unrelated symbols
5. **Test after rename** - Run tests to ensure nothing broke

## Limitations

- Won't rename symbols in strings or comments
- Won't rename across package boundaries (only your workspace)
- Requires LSP to have parsed and indexed the files
- Some macro-generated code might not be renameable
