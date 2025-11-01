# Extended Help: execute_vscode_command

## Common Command Examples

### File Operations

```julia
# Save all files
execute_vscode_command("workbench.action.files.saveAll")

# Close all editors
execute_vscode_command("workbench.action.closeAllEditors")

# Open a file
execute_vscode_command("workbench.action.files.openFile")
```

### Navigation

```julia
# Focus terminal
execute_vscode_command("workbench.action.terminal.focus")

# Focus editor
execute_vscode_command("workbench.action.focusActiveEditorGroup")

# Quick open file picker
execute_vscode_command("workbench.action.quickOpen")

# Go to line
execute_vscode_command("workbench.action.gotoLine")
```

### Terminal Operations

```julia
# Create new terminal
execute_vscode_command("workbench.action.terminal.new")

# Send command to terminal (RECOMMENDED for shell commands)
execute_vscode_command(
    "workbench.action.terminal.sendSequence",
    ["{\"text\": \"julia --project -e 'using Pkg; Pkg.test()'\\r\"}"]
)

# Kill terminal
execute_vscode_command("workbench.action.terminal.kill")
```

### Git Operations

```julia
# Refresh git
execute_vscode_command("git.refresh")

# Stage all changes
execute_vscode_command("git.stageAll")

# Commit
execute_vscode_command("git.commit")

# Push
execute_vscode_command("git.push")

# Sync
execute_vscode_command("git.sync")
```

### Julia REPL Control

```julia
# Start Julia REPL
execute_vscode_command("language-julia.startREPL")

# Restart Julia REPL
execute_vscode_command("language-julia.restartREPL")
```

### Testing

```julia
# Run all tests
execute_vscode_command("testing.runAll")

# Run test at cursor
execute_vscode_command("testing.runAtCursor")

# Run current file tests
execute_vscode_command("testing.runCurrentFile")

# Debug test at cursor
execute_vscode_command("testing.debugAtCursor")

# Re-run failed tests
execute_vscode_command("testing.reRunFailedTests")
```

### Debugging

```julia
# Start debugging
execute_vscode_command("workbench.action.debug.start")

# Stop debugging
execute_vscode_command("workbench.action.debug.stop")

# Step over
execute_vscode_command("workbench.action.debug.stepOver")

# Step into
execute_vscode_command("workbench.action.debug.stepInto")

# Step out
execute_vscode_command("workbench.action.debug.stepOut")

# Continue
execute_vscode_command("workbench.action.debug.continue")

# Add watch expression
execute_vscode_command("workbench.action.debug.addWatch")

# Toggle breakpoint
execute_vscode_command("editor.debug.action.toggleBreakpoint")
```

### Window Management

```julia
# Split editor
execute_vscode_command("workbench.action.splitEditor")

# Toggle sidebar
execute_vscode_command("workbench.action.toggleSidebarVisibility")

# Toggle panel
execute_vscode_command("workbench.action.togglePanel")

# Reload window
execute_vscode_command("workbench.action.reloadWindow")
```

### Search

```julia
# Find in files
execute_vscode_command("workbench.action.findInFiles")

# Replace in files
execute_vscode_command("workbench.action.replaceInFiles")

# Show all symbols
execute_vscode_command("workbench.action.showAllSymbols")
```

## Bidirectional Communication

Some commands return values that you can retrieve:

```julia
# Wait for response (5 second timeout)
result = execute_vscode_command(
    "someCommand",
    wait_for_response=true
)

# Custom timeout (10 seconds)
result = execute_vscode_command(
    "someCommand",
    wait_for_response=true,
    timeout=10.0
)
```

## Command with Arguments

```julia
# Run a specific task
execute_vscode_command(
    "workbench.action.tasks.runTask",
    ["build"]
)

# Send text to terminal
execute_vscode_command(
    "workbench.action.terminal.sendSequence",
    ["{\"text\": \"echo hello\\r\"}"]
)
```

## Discovering Available Commands

Use the `list_vscode_commands` tool to see all configured commands:

```julia
# Via MCP tool (for AI agents)
list_vscode_commands()

# Via Julia REPL
exec_repl("MCPRepl.list_vscode_commands()")
```

Commands must be allowlisted in `.vscode/settings.json` under `vscode-remote-control.allowedCommands`.

## Common Workflows

### Complete Test Workflow

```julia
# 1. Save all files
execute_vscode_command("workbench.action.files.saveAll")

# 2. Run tests
execute_vscode_command("testing.runAll")

# 3. If failures, re-run failed tests
execute_vscode_command("testing.reRunFailedTests")
```

### Debug Workflow

```julia
# 1. Open file and set breakpoint
# (Use open_file_and_set_breakpoint tool instead)

# 2. Start debugging
execute_vscode_command("workbench.action.debug.start")

# 3. Step through (done via debug_step_* tools)

# 4. Stop debugging
execute_vscode_command("workbench.action.debug.stop")
```

### Git Workflow

```julia
# 1. Refresh to see changes
execute_vscode_command("git.refresh")

# 2. Stage all
execute_vscode_command("git.stageAll")

# 3. Commit
execute_vscode_command("git.commit")

# 4. Push
execute_vscode_command("git.push")
```

## Troubleshooting

### Command Not Found
- Ensure the command is in the allowlist (`.vscode/settings.json`)
- Check spelling of command ID
- Use `list_vscode_commands` to see available commands

### Command Doesn't Work
- Some commands require specific context (e.g., file must be open)
- Check if command requires arguments
- Verify VS Code Remote Control extension is installed

### No Response When Using wait_for_response
- Increase timeout parameter
- Not all commands return values
- Check if command completed successfully first
