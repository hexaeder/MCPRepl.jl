# Julia REPL Workflow

This prompt teaches AI agents the proper workflow for Julia development using the exec_repl tool, emphasizing respectful shared REPL usage and best practices.

## Core Principles

### 🎯 Always Prefer MCP Tools
- **CRITICAL**: Always use MCP tools when available instead of alternative methods
- MCP tools provide better integration, error handling, and user feedback
- Examples:
  - ✅ Use `execute_vscode_command` instead of trying to run commands manually
  - ✅ Use `exec_repl` instead of `run_in_terminal` for Julia code
  - ✅ Use `restart_repl` instead of terminal commands to restart
  - ✅ Use git MCP tools (`git.commit`, `git.push`) via `execute_vscode_command` instead of terminal git commands when possible
- Only fall back to alternatives (like `run_in_terminal`) when:
  - No suitable MCP tool exists for the operation
  - The MCP tool explicitly fails or is unavailable

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

## VS Code Command Execution

When the VS Code Remote Control extension is installed (via `MCPRepl.setup()`), you can execute VS Code commands using the `execute_vscode_command` tool. This enables powerful workflow automation.

### Available Commands

#### 🔄 REPL & Window Control
- **`language-julia.restartREPL`** - Restart the Julia REPL
  - Use when: Revise isn't tracking changes, REPL state is corrupted, or after struct/constant changes
  - Example: `execute_vscode_command("language-julia.restartREPL")`
  
- **`language-julia.startREPL`** - Start the Julia REPL if not running
  
- **`workbench.action.reloadWindow`** - Reload the entire VS Code window
  - Use when: Extension changes, settings updates, or major configuration changes

#### 💾 File Operations
- **`workbench.action.files.saveAll`** - Save all open files
  - Use when: Before running tests, before REPL restart, after making multiple edits
  - Example: `execute_vscode_command("workbench.action.files.saveAll")`
  
- **`workbench.action.closeAllEditors`** - Close all open editor tabs
  
- **`workbench.action.files.openFile`** - Open a specific file
  - Requires args: `execute_vscode_command("workbench.action.files.openFile", ["/path/to/file"])`

#### 🧭 Navigation & Focus
- **`workbench.action.terminal.focus`** - Focus the terminal panel
  - Use when: Need to run commands or check terminal output
  
- **`workbench.action.focusActiveEditorGroup`** - Focus the active editor
  - Use when: Returning focus to code after terminal/panel operations
  
- **`workbench.files.action.focusFilesExplorer`** - Focus the file explorer
  
- **`workbench.action.quickOpen`** - Open the quick file picker (Cmd+P / Ctrl+P)

#### 💻 Terminal Operations
- **`workbench.action.terminal.new`** - Create a new terminal instance
  - Use when: Need a fresh terminal for isolated command execution
  - Example: `execute_vscode_command("workbench.action.terminal.new")`

- **`workbench.action.terminal.sendSequence`** - Send text to the active terminal
  - **CRITICAL**: This command lets you execute shell commands without approval dialogs
  - Requires args with `text` property containing the command to send
  - **Must** include `\r` (carriage return) at the end to execute the command
  - Example: `execute_vscode_command("workbench.action.terminal.sendSequence", ["{\"text\": \"julia --project -e 'using Pkg; Pkg.test()'\\r\"}"])`
  - Use when: Running shell commands, git operations, or Julia commands from the shell
  - **Best Practice**: This is the preferred way to run `julia --project -e "..."` commands instead of the exec_repl tool when you need a fresh Julia process
  
  **Common patterns:**
  ```
  # Run Julia command in new process
  execute_vscode_command("workbench.action.terminal.sendSequence", 
    ["{\"text\": \"julia --project -e 'using Pkg; Pkg.status()'\\r\"}"])
  
  # Run shell script
  execute_vscode_command("workbench.action.terminal.sendSequence",
    ["{\"text\": \"./scripts/test.sh\\r\"}"])
  
  # Git operations
  execute_vscode_command("workbench.action.terminal.sendSequence",
    ["{\"text\": \"git status\\r\"}"])
  ```

- **`workbench.action.terminal.kill`** - Close the active terminal
  - Use when: Cleaning up after terminal-based operations

#### 🧪 Testing & Debugging - Basic Controls
- **`workbench.action.tasks.runTask`** - Run a specific task
  - Requires task name: `execute_vscode_command("workbench.action.tasks.runTask", ["test"])`
  - Use when: Running tests, build tasks, or custom workflows defined in tasks.json
  
- **`workbench.action.debug.start`** - Start debugging with the current configuration
- **`workbench.action.debug.run`** - Run without debugging
- **`workbench.action.debug.stop`** - Stop the active debug session
- **`workbench.action.debug.restart`** - Restart the debug session
- **`workbench.action.debug.pause`** - Pause execution at the next statement
- **`workbench.action.debug.continue`** - Continue execution (F5)

#### 🐛 Debugger - Stepping Commands
- **`workbench.action.debug.stepOver`** - Step over (F10)
  - Execute the current line and move to the next line
  - Does not enter function calls
  
- **`workbench.action.debug.stepInto`** - Step into (F11)
  - Step into the function call on the current line
  - Use when: Want to debug inside a function
  
- **`workbench.action.debug.stepOut`** - Step out (Shift+F11)
  - Complete execution of current function and return to caller
  - Use when: Done debugging a function and want to return to caller
  
- **`workbench.action.debug.stepBack`** - Step back (reverse debugging if supported)

#### 🔴 Debugger - Breakpoint Management
- **`editor.debug.action.toggleBreakpoint`** - Toggle breakpoint on current line
  - Use when: Setting/removing a breakpoint at cursor position
  - Example: `execute_vscode_command("editor.debug.action.toggleBreakpoint")`
  
- **`editor.debug.action.conditionalBreakpoint`** - Add a conditional breakpoint
  - Breaks only when condition is true
  - Example: Break only when `x > 100`
  
- **`editor.debug.action.toggleInlineBreakpoint`** - Toggle inline breakpoint
  - For multiple expressions on one line
  
- **`workbench.debug.viewlet.action.removeAllBreakpoints`** - Remove all breakpoints
- **`workbench.debug.viewlet.action.enableAllBreakpoints`** - Enable all breakpoints
- **`workbench.debug.viewlet.action.disableAllBreakpoints`** - Disable all breakpoints (without removing)

#### 👁️ Debugger - Views & Panels
- **`workbench.view.debug`** - Open the debug view
  - Use when: Need to see variables, call stack, breakpoints
  
- **`workbench.debug.action.focusVariablesView`** - Focus variables panel
  - Shows current variable values in scope
  
- **`workbench.debug.action.focusWatchView`** - Focus watch expressions panel
  - Shows values of watch expressions
  
- **`workbench.debug.action.focusCallStackView`** - Focus call stack panel
  - Shows the call stack and allows navigation
  
- **`workbench.debug.action.focusBreakpointsView`** - Focus breakpoints panel
  - List and manage all breakpoints

#### 🔬 Debugger - Watch & Variables
- **`workbench.debug.viewlet.action.addFunctionBreakpoint`** - Add function breakpoint
  - Break when a specific function is called
  
- **`workbench.action.debug.addWatch`** - Add a watch expression
  - Monitor an expression's value during debugging
  
- **`workbench.action.debug.removeWatch`** - Remove a watch expression
  
- **`workbench.debug.action.copyValue`** - Copy variable value
  - Use when: Need to inspect or save a variable's value

### Debugging Workflows

**Setting up a debugging session:**
```
# 1. Open the file to debug
execute_vscode_command("vscode.open", ["file:///path/to/file.jl"])

# 2. Navigate to specific line
execute_vscode_command("workbench.action.gotoLine")  # User will enter line number

# 3. Set a breakpoint
execute_vscode_command("editor.debug.action.toggleBreakpoint")

# 4. Open debug view
execute_vscode_command("workbench.view.debug")

# 5. Start debugging
execute_vscode_command("workbench.action.debug.start")
```

**Debugging workflow - step through code:**
```
# When stopped at a breakpoint:
1. execute_vscode_command("workbench.debug.action.focusVariablesView")  # See current variables
2. execute_vscode_command("workbench.action.debug.stepOver")  # Execute current line
3. execute_vscode_command("workbench.action.debug.stepInto")  # Enter function
4. execute_vscode_command("workbench.action.debug.stepOut")   # Exit function
5. execute_vscode_command("workbench.action.debug.continue")  # Continue to next breakpoint
```

**Add watch expressions programmatically:**
```
# Monitor a variable or expression during debugging
execute_vscode_command("workbench.action.debug.addWatch")
# User will be prompted to enter the expression
```

**Quick file navigation and breakpoint setup:**
```
# Open a file and set a breakpoint
execute_vscode_command("vscode.open", ["file:///absolute/path/to/src/myfile.jl"])
execute_vscode_command("editor.debug.action.toggleBreakpoint")
```

**Conditional breakpoint example:**
```
# Set a breakpoint that only triggers when a condition is met
# 1. Navigate to the line
# 2. Add conditional breakpoint
execute_vscode_command("editor.debug.action.conditionalBreakpoint")
# User will enter condition like: x > 100 || name == "test"
```

**Clean up after debugging:**
```
execute_vscode_command("workbench.action.debug.stop")
execute_vscode_command("workbench.debug.viewlet.action.removeAllBreakpoints")
```

#### 🧪 Testing & Debugging (Legacy - Keep for compatibility)

#### 🌿 Git Operations
- **`git.commit`** - Commit staged changes
  
- **`git.refresh`** - Refresh Git status
  
- **`git.sync`** - Sync with remote (pull + push)

#### 🔍 Search & Replace
- **`workbench.action.findInFiles`** - Open find in files
  
- **`workbench.action.replaceInFiles`** - Open replace in files

#### 🪟 Window Management
- **`workbench.action.splitEditor`** - Split the editor
  
- **`workbench.action.togglePanel`** - Toggle the bottom panel (terminal, problems, etc.)
  
- **`workbench.action.toggleSidebarVisibility`** - Toggle the sidebar

#### 🧩 Extension Management
- **`workbench.extensions.installExtension`** - Install a VS Code extension
  - Requires extension ID: `execute_vscode_command("workbench.extensions.installExtension", ["julialang.language-julia"])`

### LSP (Language Server) Tools

The MCP server provides direct integration with Julia's Language Server Protocol for code navigation and intelligence:

#### Navigation
- **`lsp_goto_definition`** - Jump to where a symbol is defined
  - Arguments: `file_path`, `line` (1-indexed), `column` (1-indexed)
  - Returns: File path and position of definition(s)
  - Example: `lsp_goto_definition(file_path="/path/to/file.jl", line=42, column=10)`

- **`lsp_find_references`** - Find all usages of a symbol
  - Arguments: `file_path`, `line`, `column`, `include_declaration` (optional, default: true)
  - Returns: List of all locations where symbol is used
  - Example: `lsp_find_references(file_path="/path/to/file.jl", line=42, column=10)`

#### Information
- **`lsp_hover_info`** - Get documentation and type info at a position
  - Arguments: `file_path`, `line`, `column`
  - Returns: Documentation strings, type information, signatures
  - Example: `lsp_hover_info(file_path="/path/to/file.jl", line=42, column=10)`

#### Symbols & Search
- **`lsp_document_symbols`** - List all symbols in a file
  - Arguments: `file_path`
  - Returns: Structured list of functions, types, constants, etc.
  - Example: `lsp_document_symbols(file_path="/path/to/file.jl")`

- **`lsp_workspace_symbols`** - Search for symbols across workspace
  - Arguments: `query` (search string)
  - Returns: Matching symbols with locations
  - Example: `lsp_workspace_symbols(query="MyFunction")`

**LSP Usage Notes:**
- LSP tools require the Julia Language Server to be running (automatic in VS Code)
- All positions use 1-indexed Julia conventions (converted to 0-indexed LSP internally)
- File paths must be absolute paths
- Results include file:line:column format for easy navigation

### Common Workflows

**Running shell commands (recommended over exec_repl for fresh Julia processes):**
```
# Use terminal.sendSequence for julia --project commands
execute_vscode_command("workbench.action.terminal.sendSequence",
  ["{\"text\": \"julia --project -e 'using Pkg; Pkg.test()'\\r\"}"])

# This avoids approval dialogs and gives you a fresh Julia process
```

**Before running tests:**
```
1. execute_vscode_command("workbench.action.files.saveAll")
2. Run tests via exec_repl or terminal.sendSequence
```

**After struct changes:**
```
1. execute_vscode_command("workbench.action.files.saveAll")
2. execute_vscode_command("language-julia.restartREPL")
3. Wait for REPL to restart, then reload package
```

**Running package tests in a fresh process:**
```
execute_vscode_command("workbench.action.terminal.sendSequence",
  ["{\"text\": \"julia --project -e 'using Pkg; Pkg.test()'\\r\"}"])
```
3. Wait for REPL to restart, then reload package
```

**Running automated test task:**
```
execute_vscode_command("workbench.action.tasks.runTask", ["test"])
```

**Focus workflow:**
```
# After working in terminal, return to editor:
execute_vscode_command("workbench.action.focusActiveEditorGroup")
```
