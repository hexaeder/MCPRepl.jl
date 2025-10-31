# ============================================================================
# Generate Module - Project Template Generator
# ============================================================================

"""
    Generate

Module for generating complete Julia project templates pre-configured with MCPRepl.

Provides the `generate` function to create new projects with all necessary 
configuration files for AI agent integration.
"""
module Generate

using Pkg
using JSON
using SHA
using Dates
using Suppressor

# Import the parent module to access its functions
import ..MCPRepl

export generate
# Export file generation functions for use by setup.jl
export create_security_config, create_startup_script, create_repl_script
export create_vscode_config, create_vscode_settings, create_claude_config_template
export create_gemini_config_template, create_gitignore, create_env_file
export create_claude_env_settings
# Export the VS Code commands constant for testing
export VSCODE_ALLOWED_COMMANDS

# VS Code Remote Control allowed commands list
# This list is used in generated .vscode/settings.json files
const VSCODE_ALLOWED_COMMANDS = [
    "editor.action.goToLocations",
    "editor.debug.action.conditionalBreakpoint",
    "editor.debug.action.toggleBreakpoint",
    "editor.debug.action.toggleInlineBreakpoint",
    "git.branchFrom",
    "git.commit",
    "git.fetch",
    "git.pull",
    "git.push",
    "git.refresh",
    "git.sync",
    "language-julia.restartREPL",
    "language-julia.startREPL",
    "testing.cancelRun",
    "testing.debugAll",
    "testing.debugAtCursor",
    "testing.debugCurrentFile",
    "testing.openOutputPeek",
    "testing.reRunFailedTests",
    "testing.reRunLastRun",
    "testing.runAll",
    "testing.runAtCursor",
    "testing.runCurrentFile",
    "testing.showMostRecentOutput",
    "testing.toggleTestingView",
    "vscode.open",
    "vscode.openWith",
    "workbench.action.closeAllEditors",
    "workbench.action.debug.addWatch",
    "workbench.action.debug.continue",
    "workbench.action.debug.pause",
    "workbench.action.debug.removeWatch",
    "workbench.action.debug.restart",
    "workbench.action.debug.run",
    "workbench.action.debug.start",
    "workbench.action.debug.stepBack",
    "workbench.action.debug.stepInto",
    "workbench.action.debug.stepOut",
    "workbench.action.debug.stepOver",
    "workbench.action.debug.stop",
    "workbench.action.files.openFile",
    "workbench.action.files.saveAll",
    "workbench.action.findInFiles",
    "workbench.action.focusActiveEditorGroup",
    "workbench.action.gotoLine",
    "workbench.action.navigateToLastEditLocation",
    "workbench.action.quickOpen",
    "workbench.action.reloadWindow",
    "workbench.action.replaceInFiles",
    "workbench.action.showAllSymbols",
    "workbench.action.splitEditor",
    "workbench.action.tasks.runTask",
    "workbench.action.terminal.focus",
    "workbench.action.terminal.kill",
    "workbench.action.terminal.new",
    "workbench.action.terminal.sendSequence",
    "workbench.action.togglePanel",
    "workbench.action.toggleSidebarVisibility",
    "workbench.debug.action.copyValue",
    "workbench.debug.action.focusBreakpointsView",
    "workbench.debug.action.focusCallStackView",
    "workbench.debug.action.focusVariablesView",
    "workbench.debug.action.focusWatchView",
    "workbench.debug.viewlet.action.addFunctionBreakpoint",
    "workbench.debug.viewlet.action.disableAllBreakpoints",
    "workbench.debug.viewlet.action.enableAllBreakpoints",
    "workbench.debug.viewlet.action.removeAllBreakpoints",
    "workbench.extensions.installExtension",
    "workbench.files.action.focusFilesExplorer",
    "workbench.view.debug",
    "workbench.view.testing.focus",
    # VS Code LSP command providers (used by LSP tools)
    "vscode.executeCodeActionProvider",
    "vscode.executeDefinitionProvider",
    "vscode.executeDocumentRenameProvider",
    "vscode.executeDocumentSymbolProvider",
    "vscode.executeFormatDocumentProvider",
    "vscode.executeFormatRangeProvider",
    "vscode.executeReferenceProvider",
    "vscode.executeWorkspaceSymbolProvider",
]

"""
    generate(project_name::String; 
             security_mode::Symbol=:lax, 
             port::Int=3000,
             path::String=pwd(),
             emoticon::String="🐉")

Generate a complete Julia project template with MCPRepl integration.

Creates a new Julia package with:
- Basic project structure (Project.toml, src/, test/)
- Security configuration (.mcprepl/security.json)
- Julia startup script (.julia-startup.jl)
- VS Code configuration (.vscode/mcp.json, .vscode/settings.json)
- Claude Desktop configuration template
- Gemini configuration template
- README.md with usage instructions
- AGENTS.md with AI agent guidelines
- .gitignore configured for MCPRepl files

# Arguments
- `project_name::String`: Name of the project to create
- `security_mode::Symbol=:lax`: Security mode (:strict, :relaxed, or :lax)
- `port::Int=3000`: Port for the MCP server
- `path::String=pwd()`: Parent directory where project will be created
- `emoticon::String="🐉"`: Emoticon to use in startup messages

# Returns
- `String`: Path to the created project directory

# Examples
```julia
# Create a local development project
MCPRepl.Generate.generate("MyProject")

# Create a production-ready project with strict security
MCPRepl.Generate.generate("MySecureProject", security_mode=:strict, port=3001)

# Create project in a specific directory
MCPRepl.Generate.generate("MyProject", path="/Users/name/projects")
```

# Security Modes
- `:lax` - Localhost only, no API key (default for quick development)
- `:relaxed` - API key required, any IP allowed
- `:strict` - API key required + IP allowlist enforced
"""
function generate(
    project_name::String;
    security_mode::Symbol = :lax,
    port::Int = 3000,
    path::String = pwd(),
    emoticon::String = "🐉",
)
    # Validate inputs
    if !(security_mode in [:strict, :relaxed, :lax])
        error("Invalid security_mode. Must be :strict, :relaxed, or :lax")
    end

    if port < 1024 || port > 65535
        @warn "Port $port may require special permissions or is out of range. Recommended: 3000-9999"
    end


    # Create project directory
    project_path = joinpath(path, project_name)
    # Projects should generally not include the .jl suffix in the name, but the directory should

    if !endswith(project_path, ".jl")
        project_path = project_path * ".jl"
    end
    if endswith(project_name, ".jl")
        project_name = replace(project_name, r"\.jl$" => "")
    end
    if isdir(project_path)
        error("Project directory already exists: $project_path")
    end

    println("🚀 Generating Julia project: $project_name")
    println("   Location: $project_path")
    println("   Security: $security_mode")
    println("   Port: $port")
    println()

    # Use Pkg.generate to create basic structure
    println("📦 Creating project structure...")
    original_dir = pwd()
    try
        cd(path)
        @suppress Pkg.generate(project_path)
    finally
        cd(original_dir)
    end

    # Generate all configuration files
    create_security_config(project_path, security_mode, port)

    # Get API key for VS Code config (if not lax mode)
    api_key = nothing
    if security_mode != :lax
        security_config_path = joinpath(project_path, ".mcprepl", "security.json")
        security_data = JSON.parsefile(security_config_path)
        api_keys = get(security_data, "api_keys", String[])
        if !isempty(api_keys)
            api_key = first(api_keys)
        end
    end

    create_startup_script(project_path, port, emoticon)
    create_repl_script(project_path)
    create_env_file(project_path, port, api_key)
    create_claude_env_settings(project_path, port, api_key)
    create_vscode_config(project_path, port, api_key)
    create_vscode_settings(project_path)
    create_claude_config_template(project_path, port, api_key)
    create_gemini_config_template(project_path, port, api_key)
    _create_readme(project_path, project_name, security_mode, port)
    _create_agents_guide(project_path, project_name)
    create_gitignore(project_path)
    _enhance_test_file(project_path, project_name)  # Do this before Pkg operations
    _add_mcprepl_dependency(project_path)

    println()
    println("✅ Project generated successfully!")
    println()
    println("📍 Next steps:")
    println("   1. cd $project_path")
    println("   2. ./repl          # or: julia --project=. --load=.julia-startup.jl")
    println("   3. The MCP server will start automatically!")
    println()
    println("🤖 For AI agents, see AGENTS.md in the project directory")
    println()

    return project_path
end

# ============================================================================
# Internal Helper Functions
# ============================================================================

function create_security_config(project_path::String, mode::Symbol, port::Int)
    println("🔒 Creating security configuration...")

    config_dir = joinpath(project_path, ".mcprepl")
    mkpath(config_dir)

    # Generate API keys if not in lax mode
    api_keys = if mode == :lax
        String[]
    else
        [MCPRepl.generate_api_key()]
    end

    # Set up IP allowlist for strict mode
    allowed_ips = if mode == :strict
        ["127.0.0.1", "::1"]  # Start with localhost, user can add more
    else
        String[]
    end

    # Create security config
    config = MCPRepl.SecurityConfig(mode, api_keys, allowed_ips, port)

    # Save to file
    config_path = joinpath(config_dir, "security.json")
    config_data = Dict(
        "mode" => string(config.mode),
        "api_keys" => config.api_keys,
        "allowed_ips" => config.allowed_ips,
        "port" => config.port,
        "created_at" => config.created_at,
    )

    write(config_path, JSON.json(config_data, 2))

    # Set restrictive permissions on Unix-like systems
    if !Sys.iswindows()
        chmod(config_path, 0o600)
    end

    if mode != :lax && !isempty(api_keys)
        println("   ✓ Generated API key: $(first(api_keys))")
        println("   ⚠️  Store this key securely - you'll need it for client configuration")
    end
end

function create_startup_script(project_path::String, port::Int, emoticon::String = "🐉")
    println("📝 Creating Julia startup script...")

    startup_content = """
using Pkg
Pkg.activate(".")
import Base.Threads

# Load Revise for hot reloading (optional but recommended)
try
    using Revise
    @info "✓ Revise loaded - code changes will be tracked and auto-reloaded"
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\\"Revise\\"))"
end
using MCPRepl
# Start MCP REPL server for AI agent integration
try
    if Threads.threadid() == 1
        Threads.@spawn begin
            try
                sleep(1)
                # Port is determined by:
                # 1. JULIA_MCP_PORT environment variable (highest priority)
                # 2. .mcprepl/security.json port field (default)
                MCPRepl.start!(verbose=false)

                # Wait a moment for server to fully initialize
                sleep(0.5)

                @info "✓ MCP REPL server started $emoticon"
                # Refresh the prompt to ensure clean display
                if isdefined(Base, :active_repl)
                    try
                        println()  # Add clean newline
                        REPL.LineEdit.refresh_line(Base.active_repl.mistate)
                    catch
                        # Ignore if REPL isn't ready yet
                    end
                end
            catch e
                @warn "Could not start MCP REPL server" exception=e
            end
        end
    end
catch e
    @warn "Could not start MCP REPL server" exception=e
end
"""

    startup_path = joinpath(project_path, ".julia-startup.jl")
    write(startup_path, startup_content)
    return true
end

function create_repl_script(project_path::String)
    println("🚀 Creating repl launcher script...")
    repl_content = """#!/usr/bin/env bash

# Start Julia REPL with MCPRepl project and auto-load startup script
# This script launches Julia in the project and loads the recommended startup
# script. Environment configuration is expected to be stored in project
# configuration (.mcprepl/security.json) or a project .env file managed by
# the project tools — the launcher intentionally does not alter environment
# variables.

SCRIPT_DIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" && pwd )"

echo "Starting Julia REPL with MCPRepl project..."
echo ""

exec julia --project="\$SCRIPT_DIR" --load="\$SCRIPT_DIR/.julia-startup.jl" "\$@"
"""

    repl_path = joinpath(project_path, "repl")
    write(repl_path, repl_content)

    # Make it executable on Unix-like systems
    if !Sys.iswindows()
        try
            chmod(repl_path, 0o755)
        catch
            # Silently fail if chmod isn't available
        end
    end

    return true
end

function create_env_file(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("🔐 Creating .env file...")

    env_content = "# MCPRepl Environment Configuration\n"
    env_content *= "# This file contains sensitive information - DO NOT COMMIT\n\n"

    if api_key !== nothing
        env_content *= "JULIA_MCP_API_KEY=$api_key\n"
    end

    env_content *= "JULIA_MCP_PORT=$port\n"

    env_path = joinpath(project_path, ".env")
    write(env_path, env_content)

    return true
end

function create_claude_env_settings(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("🔐 Creating .claude/settings.local.json...")

    claude_dir = joinpath(project_path, ".claude")
    mkpath(claude_dir)

    settings =
        Dict("env" => Dict{String,String}(), "enabledMcpjsonServers" => ["julia-repl"])

    if api_key !== nothing
        settings["env"]["JULIA_MCP_API_KEY"] = api_key
    end

    # Always add the port
    settings["env"]["JULIA_MCP_PORT"] = string(port)

    settings_path = joinpath(claude_dir, "settings.local.json")
    write(settings_path, JSON.json(settings, 2))

    return true
end

function create_vscode_config(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("⚙️  Creating VS Code MCP configuration...")

    vscode_dir = joinpath(project_path, ".vscode")
    mkpath(vscode_dir)

    # Build server config with hardcoded values
    # NOTE: Claude Code does not support environment variable expansion in mcp.json
    # So we hardcode the values here and add the file to .gitignore
    server_config = Dict{String,Any}("type" => "http", "url" => "http://localhost:$port")

    # Add Authorization header if api_key is provided
    if api_key !== nothing
        server_config["headers"] = Dict{String,Any}("Authorization" => "Bearer $api_key")
    end

    mcp_config = Dict("servers" => Dict("julia-repl" => server_config), "inputs" => [])

    mcp_path = joinpath(vscode_dir, "mcp.json")
    write(mcp_path, JSON.json(mcp_config, 2))

    return true
end

function create_vscode_settings(project_path::String)
    println("⚙️  Creating VS Code settings...")

    vscode_dir = joinpath(project_path, ".vscode")
    mkpath(vscode_dir)

    settings = Dict(
        "julia.environmentPath" => "\${workspaceFolder}",
        "julia.additionalArgs" => ["--load=\${workspaceFolder}/.julia-startup.jl"],
        "vscode-remote-control.allowedCommands" => VSCODE_ALLOWED_COMMANDS,
    )

    settings_path = joinpath(vscode_dir, "settings.json")
    write(settings_path, JSON.json(settings, 2))
end

function create_claude_config_template(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("🤖 Creating Claude Desktop config template...")

    config_template = if api_key === nothing
        """
{
  "mcpServers": {
    "julia-repl": {
      "type": "http",
      "url": "http://localhost:\${JULIA_MCP_PORT}"
    }
  }
}
"""
    else
        """
{
  "mcpServers": {
    "julia-repl": {
      "type": "http",
      "url": "http://localhost:\${JULIA_MCP_PORT}",
      "headers": {
        "Authorization": "Bearer \${JULIA_MCP_API_KEY}"
      }
    }
  }
}
"""
    end

    template_path = joinpath(project_path, ".mcp.json")
    write(template_path, config_template)

    return true
end

function create_gemini_config_template(
    project_path::String,
    port::Int,
    api_key::Union{String,Nothing} = nothing,
)
    println("💎 Creating Gemini config...")

    config_template = if api_key === nothing
        """
{
  "mcpServers": {
    "julia-repl": {
      "url": "http://localhost:\${JULIA_MCP_PORT}"
    }
  }
}
"""
    else
        """
{
  "mcpServers": {
    "julia-repl": {
      "url": "http://localhost:\${JULIA_MCP_PORT}",
      "headers": {
        "Authorization": "Bearer \${JULIA_MCP_API_KEY}"
      }
    }
  }
}
"""
    end

    # Write to both locations: project template and user's .gemini directory
    template_path = joinpath(project_path, "gemini-settings.json")
    write(template_path, config_template)

    # Also write to ~/.gemini/settings.json
    gemini_dir = joinpath(homedir(), ".gemini")
    mkpath(gemini_dir)
    gemini_config_path = joinpath(gemini_dir, "settings.json")
    write(gemini_config_path, config_template)

    println("   ✓ Written to ~/.gemini/settings.json")
    return true
end

function _create_readme(project_path::String, project_name::String, mode::Symbol, port::Int)
    println("📖 Creating README.md...")

    # Load security config for API key
    security_config_path = joinpath(project_path, ".mcprepl", "security.json")
    security_data = JSON.parsefile(security_config_path)
    api_keys = get(security_data, "api_keys", String[])
    has_api_key = !isempty(api_keys)

    readme_content = """
# $project_name

A Julia project with AI agent integration via MCPRepl.

## Quick Start

```bash
cd $project_name
./repl
```

The MCP server will start automatically when Julia launches!

## Project Structure

```
$project_name/
├── src/                # Source code
├── test/               # Test suite
├── .mcprepl/           # Security configuration (git-ignored)
├── .vscode/            # VS Code MCP config
└── AGENTS.md           # AI agent guidelines
```

## Security

**Mode**: `$mode` | **Port**: `$port`$(has_api_key ? " | **API Key**: See `.env`" : " | **Auth**: None (localhost only)")

$(has_api_key ? """
### Environment Setup

Your API key is in `.env` and `.claude/settings.local.json` (both git-ignored).

- **VS Code**: Auto-loads `.env`
- **Claude Desktop**: Auto-loads `.claude/settings.local.json`  
- **Other tools**: Set `JULIA_MCP_API_KEY` and `JULIA_MCP_PORT` manually

To view your key: `cat .env`

To change security mode:

```julia
using MCPRepl
MCPRepl.setup()
```
""" : """
To change security mode:

```julia
using MCPRepl
MCPRepl.setup()
```
""")

## AI Agent Integration

**For AI agents**: See [AGENTS.md](AGENTS.md) for detailed guidelines.

**VS Code**: Open project, start Julia REPL$(has_api_key ? " (`.env` auto-loaded)" : "")  
**Claude Desktop**: Config in `.mcp.json`$(has_api_key ? " (`.claude/settings.local.json` auto-loaded)" : "")  
**Gemini**: Configured in `~/.gemini/settings.json`$(has_api_key ? " (`.env` auto-loaded)" : "")

## Troubleshooting

**Port in use?** Override with: `JULIA_MCP_PORT=3001 julia --project=.`

**Auth fails?** Check API key: `cat .env`

**Server won't start?** Restart Julia or check port: `lsof -i :$port`

## License

$(isfile(joinpath(project_path, "LICENSE")) ? "[MIT License](LICENSE)" : "See LICENSE file")
"""

    readme_path = joinpath(project_path, "README.md")
    write(readme_path, readme_content)
end

function _create_agents_guide(project_path::String, project_name::String)
    println("🤖 Creating AGENTS.md...")

    agents_content = """
# AI Agent Guidelines for $project_name

This document provides guidelines for AI agents working with this Julia project via MCPRepl.

## Overview

This project is configured with MCPRepl, which exposes the Julia REPL to AI agents via the Model Context Protocol (MCP). This enables you to:

- Execute Julia code in a persistent REPL session
- Run and fix tests interactively
- Inspect package environment and dependencies
- Use Julia's introspection tools
- Debug issues in real-time

## Available Tools

MCPRepl provides these MCP tools:

### Core Tools

- **`exec_repl`** - Execute Julia code in the shared REPL
- **`usage_instructions`** - Get detailed workflow guidelines (READ THIS FIRST!)
- **`investigate_environment`** - Inspect project setup, packages, and dev dependencies

### Development Tools

- **`search_methods`** - Find all methods of a function
- **`type_info`** - Get type hierarchy and field information
- **`macro_expand`** - Expand macros to see generated code
- **`list_names`** - List exported names in a module
- **`profile_code`** - Profile code for performance bottlenecks

### Code Quality (Optional)

- **`format_code`** - Format Julia code (requires JuliaFormatter.jl)
- **`lint_package`** - Run quality checks (requires Aqua.jl)

### VS Code Integration

- **`execute_vscode_command`** - Trigger VS Code commands
- **`restart_repl`** - Restart the Julia REPL
- **`open_file_and_set_breakpoint`** - Set up debugging
- **`start_debug_session`** - Begin debugging

### LSP Integration

- **`lsp_goto_definition`** - Jump to symbol definition
- **`lsp_find_references`** - Find all symbol references
- **`lsp_hover_info`** - Get documentation and type info
- **`lsp_completions`** - Get code completions
- **`lsp_document_symbols`** - List all symbols in file
- **`lsp_format_document`** - Format entire file
- **`lsp_code_actions`** - Get quick fixes and refactorings
- **`lsp_rename`** - Rename symbol workspace-wide

## Workflow Best Practices

### 1. Start with Usage Instructions

**ALWAYS** call `usage_instructions` before using `exec_repl`:

```json
{
  "name": "usage_instructions"
}
```

This provides critical information about REPL etiquette and best practices.

### 2. Understand the Environment

Before making changes, investigate the project setup:

```json
{
  "name": "investigate_environment"
}
```

This shows:
- Current working directory
- Active project and packages
- Development packages (tracked by Revise)
- Revise.jl status

### 3. Execute Code Responsibly

The REPL is **shared** - your code appears in the user's REPL too. Be respectful:

- ✅ Test incrementally
- ✅ Use descriptive variable names
- ✅ Clean up after yourself
- ❌ Don't flood the REPL with verbose output
- ❌ Don't change `Pkg.activate()` (it's pre-configured)

### 4. Work with Tests

Run tests interactively to fix issues one by one:

```julia
# Run a specific test
@testset "My Feature" begin
    @test my_function(input) == expected
end
```

This avoids "time-to-first-plot" issues by reusing the warm REPL.

### 5. Use Introspection Tools

Julia has powerful introspection. Use it!

```julia
# Get help
?function_name

# See all methods
methods(function_name)

# Inspect types
typeof(x)
fieldnames(MyType)
supertype(MyType)
subtypes(AbstractType)

# Check type stability
@code_warntype my_function(arg)
```

### 6. Hot Reloading with Revise

If Revise.jl is loaded, changes to files are automatically tracked:

- Edit source files directly
- Changes are reflected immediately in the REPL
- No need to restart Julia!

**Note**: If Revise isn't tracking changes, restart the REPL:

```json
{
  "name": "restart_repl"
}
```

Then wait 5-10 seconds for Julia to restart.

### 7. LSP for Code Intelligence

Use LSP tools for advanced code navigation and refactoring:

```json
{
  "name": "lsp_goto_definition",
  "arguments": {
    "file_path": "/absolute/path/to/file.jl",
    "line": 42,
    "column": 10
  }
}
```

LSP provides IDE-level intelligence without leaving the MCP interface.

## Common Tasks

### Running Tests

```julia
using Pkg
Pkg.test()
```

Or run specific test files:

```julia
include("test/specific_test.jl")
```

### Adding Dependencies

```julia
using Pkg
Pkg.add("PackageName")
```

### Checking Package Status

```julia
using Pkg
Pkg.status()
```

### Profiling Performance

```json
{
  "name": "profile_code",
  "arguments": {
    "code": "my_function(arguments)"
  }
}
```

### Debugging

1. Set breakpoint: `open_file_and_set_breakpoint`
2. Start debugging: `start_debug_session`
3. Use step commands: `debug_step_over`, `debug_step_into`, `debug_step_out`
4. Inspect variables: `copy_debug_value`

## Project-Specific Notes

### Module Structure

The main module is `$project_name`, defined in `src/$project_name.jl`.

To use it:

```julia
using $project_name
```

### Test Structure

Tests are in `test/runtests.jl`. Run with:

```julia
using Pkg
Pkg.test()
```

### Development Packages

Check which packages are under development:

```json
{
  "name": "investigate_environment"
}
```

Development packages are tracked by Revise for hot reloading.

## Security Notes

This project uses MCPRepl's security system:

- Always respect the configured security mode
- Don't attempt to bypass authentication
- Don't expose sensitive data in REPL output
- Be aware that REPL output is visible to the user

### Configuration Files and Security

**Important**: Configuration files contain sensitive information:

- `.vscode/mcp.json` - **Hardcoded API key** (git-ignored, do not commit)
- `.mcprepl/security.json` - Master security config (git-ignored)
- `.env` - Environment variables for other tools (git-ignored)
- `.claude/settings.local.json` - Claude Desktop config (git-ignored)

Template files (`claude-mcp-config.json`, `gemini-settings.json`) use environment variable placeholders
and can be safely committed. The actual values are loaded from `.env` at runtime.

**For AI Agents**: If authentication fails:
1. For VS Code/Claude Code: Check `.vscode/mcp.json` has correct hardcoded API key
2. For other tools: Check `.env` or `.claude/settings.local.json` exists with correct values
3. Confirm the values match those in `.mcprepl/security.json`
4. Remind users to restart their terminal/IDE after configuration changes

## Troubleshooting

### REPL seems stuck

The REPL might be waiting for input or processing a long operation. Use `Ctrl+C` in the Julia REPL to interrupt.

### Code changes not reflected

1. Check if Revise is loaded: `isdefined(Main, :Revise)`
2. If not, consider restarting: Use `restart_repl` tool
3. Wait 5-10 seconds after restart before continuing

### Cannot find package/module

1. Check package status: `Pkg.status()`
2. Verify you're in the right project: `Base.active_project()`
3. Install missing package: `Pkg.add("PackageName")`

### LSP not responding

1. Ensure file paths are absolute
2. Check that Julia LSP extension is running in VS Code
3. Try reloading the window: `execute_vscode_command("workbench.action.reloadWindow")`

## Resources

- [MCPRepl.jl Documentation](https://github.com/kahliburke/MCPRepl.jl)
- [Julia Documentation](https://docs.julialang.org/)
- [Julia REPL Documentation](https://docs.julialang.org/en/v1/stdlib/REPL/)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)

## Questions?

If you're unsure about something, use the `usage_instructions` tool for detailed guidance on REPL workflows and best practices.

Happy coding! 🚀
"""

    agents_path = joinpath(project_path, "AGENTS.md")
    write(agents_path, agents_content)
end

function create_gitignore(project_path::String)
    println("📝 Creating .gitignore...")

    gitignore_content = """
# Julia
*.jl.*.cov
*.jl.cov
*.jl.mem
/Manifest.toml
/docs/build/
/docs/site/

# MCPRepl - security config contains API keys
.mcprepl/
.julia-startup.jl

# Environment variables - contains API keys and ports
.env
.claude/

# VS Code - mcp.json contains hardcoded API keys
.vscode/*
!.vscode/settings.json

# MCP client configs - contain hardcoded API keys/ports
# Note: These template files use env vars but are safe to commit
# claude-mcp-config.json
# gemini-settings.json

# OS
.DS_Store
Thumbs.db

# IDE
.idea/
*.swp
*.swo
*~

# Temporary files
*.tmp
*.log
"""

    gitignore_path = joinpath(project_path, ".gitignore")
    write(gitignore_path, gitignore_content)
end

function _add_mcprepl_dependency(project_path::String)
    println("📦 Adding MCPRepl dependency...")

    # Activate the project and add MCPRepl
    original_dir = pwd()
    try
        cd(project_path)
        @suppress Pkg.activate(".")

        # Add MCPRepl (handles both registered and unregistered cases)
        try
            @suppress Pkg.add("MCPRepl")
        catch
            # If not registered, add from GitHub
            @suppress Pkg.add(url = "https://github.com/kahliburke/MCPRepl.jl")
        end

        # Add recommended development tools
        println("   Adding recommended development packages...")
        try
            @suppress Pkg.add("Revise")  # For hot reloading
        catch e
            @warn "Could not add Revise" exception = e
        end

        # Return to original environment
        @suppress Pkg.activate()
    finally
        cd(original_dir)
    end
end

function _enhance_test_file(project_path::String, project_name::String)
    println("🧪 Enhancing test file...")

    test_content = """
using $project_name
using Test

@testset "$project_name.jl" begin
    @testset "Basic functionality" begin
        # Add your tests here
        @test true
    end
end
"""

    try
        test_dir = joinpath(project_path, "test")
        # Ensure test directory exists
        if !isdir(test_dir)
            mkpath(test_dir)
        end

        test_path = joinpath(test_dir, "runtests.jl")
        write(test_path, test_content)
        println("   ✓ Created test/runtests.jl")
    catch e
        @warn "Failed to create test file" exception = e
        println("   ⚠️  Could not create test file (you may need to create it manually)")
    end
end

end # module Generate
