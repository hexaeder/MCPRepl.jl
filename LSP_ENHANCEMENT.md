# LSP Enhancement - Comprehensive Code Intelligence

## Overview

MCPRepl.jl now includes 12 comprehensive LSP (Language Server Protocol) tools that provide AI agents with the same code intelligence capabilities available in VS Code. This enables intelligent code navigation, refactoring, completion, and formatting.

## New LSP Tools Added

### 1. **lsp_rename** - Safe Symbol Renaming
Rename a function, variable, or type across the entire workspace using LSP.

**Benefits:**
- Renames all usages consistently
- Respects scope and shadowing
- Shows all changes before applying
- Much more reliable than text search/replace

**Parameters:**
- `file_path`: File containing the symbol
- `line`: Line number (1-indexed)
- `column`: Column number (1-indexed)
- `new_name`: New name for the symbol

**Example:**
```julia
lsp_rename(
    file_path = "/path/to/file.jl",
    line = 42,
    column = 10,
    new_name = "better_function_name"
)
```

### 2. **lsp_code_actions** - Quick Fixes & Refactorings
Get available quick fixes, refactorings, and code actions for errors or warnings.

**Benefits:**
- Discover available fixes for errors
- Get refactoring suggestions
- Similar to clicking the lightbulb in VS Code
- Can filter by action kind (quickfix, refactor, source, etc.)

**Parameters:**
- `file_path`: File path
- `start_line`, `start_column`: Start position
- `end_line`, `end_column`: End position (optional)
- `kind`: Filter by action type (optional)

**Example:**
```julia
lsp_code_actions(
    file_path = "/path/to/file.jl",
    start_line = 42,
    start_column = 10,
    kind = "quickfix"  # Optional: only show quick fixes
)
```

### 3. **lsp_document_highlights** - Find Symbol Occurrences
Highlight all read/write occurrences of a symbol within a single file.

**Benefits:**
- Faster than find_references for same-file searches
- Distinguishes between read and write access
- Useful for local refactoring

**Parameters:**
- `file_path`: File path
- `line`: Line number
- `column`: Column number

**Example:**
```julia
lsp_document_highlights(
    file_path = "/path/to/file.jl",
    line = 42,
    column = 10
)
```

### 4. **lsp_completions** - Intelligent Code Completion
Get code completion suggestions at a specific position.

**Benefits:**
- Discover available functions, types, and keywords
- Explore APIs without reading documentation
- Context-aware suggestions
- Shows parameter types and documentation

**Parameters:**
- `file_path`: File path
- `line`: Line number
- `column`: Column number
- `trigger_character`: Optional trigger (e.g., ".")

**Example:**
```julia
lsp_completions(
    file_path = "/path/to/file.jl",
    line = 42,
    column = 10
)
```

### 5. **lsp_signature_help** - Function Signatures
Get function signature and parameter information.

**Benefits:**
- Understand function parameters without docs
- See parameter types and descriptions
- Know which parameter is currently active

**Parameters:**
- `file_path`: File path
- `line`: Line number
- `column`: Column number

**Example:**
```julia
lsp_signature_help(
    file_path = "/path/to/file.jl",
    line = 42,
    column = 10
)
```

### 6. **lsp_format_document** - Format Entire File
Format an entire Julia file according to style guidelines.

**Benefits:**
- Consistent code formatting
- Automatic indentation and spacing
- Uses Julia LSP formatter

**Parameters:**
- `file_path`: File to format

**Example:**
```julia
lsp_format_document(file_path = "/path/to/file.jl")
```

### 7. **lsp_format_range** - Format Code Range
Format only specific lines of code.

**Benefits:**
- Format just changed sections
- Faster than full document format
- Preserve rest of file

**Parameters:**
- `file_path`: File path
- `start_line`, `start_column`: Start position
- `end_line`, `end_column`: End position

**Example:**
```julia
lsp_format_range(
    file_path = "/path/to/file.jl",
    start_line = 10,
    start_column = 1,
    end_line = 20,
    end_column = 1
)
```

## Existing LSP Tools (Already Available)

1. **lsp_goto_definition** - Jump to symbol definition
2. **lsp_find_references** - Find all symbol usages
3. **lsp_hover_info** - Get hover documentation and types
4. **lsp_document_symbols** - Get file outline/structure
5. **lsp_workspace_symbols** - Search for symbols across workspace

## AI Agent Use Cases

### 1. Intelligent Refactoring
```
Agent: I'll rename this poorly named variable across all files
lsp_find_references() -> see all usages
lsp_rename() -> safely rename everywhere
```

### 2. Error Fixing
```
Agent: There's an error here, let me get available fixes
lsp_code_actions(kind="quickfix") -> get available fixes
Apply the fix
```

### 3. API Exploration
```
Agent: I need to understand what methods are available
lsp_completions() -> see all available functions
lsp_signature_help() -> understand parameters
lsp_hover_info() -> read documentation
```

### 4. Code Navigation
```
Agent: Let me trace how this function is used
lsp_goto_definition() -> find implementation
lsp_find_references() -> find all callers
lsp_document_symbols() -> see structure
```

### 5. Code Cleanup
```
Agent: Let me format this file properly
lsp_format_document() -> consistent formatting
```

## Technical Implementation

### Architecture
- All LSP tools use VS Code's built-in LSP commands (vscode.execute*Provider)
- Bidirectional communication via Remote Control extension
- Timeout handling for long-running operations
- Comprehensive error handling and reporting

### Formatting Functions
Added helper functions to format LSP results:
- `format_workspace_edit()` - Format rename results
- `format_code_actions()` - Format available actions
- `format_highlights()` - Format highlighted occurrences
- `format_completions()` - Format completion items
- `format_signature_help()` - Format function signatures
- `format_text_edits()` - Format formatting results
- `completion_kind_to_string()` - Convert completion types to readable names

### VS Code Integration
Updated `prompts/vscode_commands.json` to include new LSP commands:
- vscode.executeCodeActionProvider
- vscode.executeDocumentRenameProvider
- vscode.executeDocumentHighlightProvider
- vscode.executeCompletionItemProvider
- vscode.executeSignatureHelpProvider
- vscode.executeFormatDocumentProvider
- vscode.executeFormatRangeProvider

## Testing

Updated `test/lsp_tests.jl` to verify all 12 LSP tools are created correctly and have proper parameters.

## Documentation

Updated README.md with:
- New LSP Integration section
- Description of all LSP tools
- Example usage
- AI agent benefits

## Future Enhancements (Potential)

Additional LSP features that could be added:
- **Call Hierarchy** - Navigate function call graphs (incoming/outgoing calls)
- **Type Hierarchy** - Navigate type inheritance (supertypes/subtypes)
- **Code Lenses** - Get inline actionable information
- **Inlay Hints** - Get type annotations and parameter names
- **Document Links** - Find and resolve links in comments/strings
- **Folding Ranges** - Get code folding information
- **Selection Ranges** - Get smart selection ranges
- **Semantic Tokens** - Get detailed token information for highlighting

These features use additional LSP commands that are already available in VS Code but not yet implemented in MCPRepl.

## Performance Considerations

- LSP operations are fast (usually <100ms)
- Formatting can take longer (up to 15s timeout)
- Completions limited to 20 results to avoid overwhelming output
- All operations use async communication with timeout handling

## Summary

This enhancement transforms MCPRepl from a simple REPL bridge into a comprehensive code intelligence platform for AI agents. Agents can now navigate, understand, refactor, and format code with the same intelligence as a human developer using VS Code.

The rename tool specifically addresses the inefficiency mentioned, enabling AI agents to safely rename symbols across an entire codebase using LSP instead of error-prone text search/replace.
