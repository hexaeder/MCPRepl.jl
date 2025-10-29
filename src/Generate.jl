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

# Import the parent module to access its functions
import ..MCPRepl

export generate

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
        Pkg.generate(project_name)
    finally
        cd(original_dir)
    end

    # Generate all configuration files
    _create_security_config(project_path, security_mode, port)
    _create_startup_script(project_path, emoticon)
    _create_vscode_config(project_path, security_mode, port)
    _create_vscode_settings(project_path)
    _create_claude_config_template(project_path, security_mode, port)
    _create_gemini_config_template(project_path, security_mode, port)
    _create_readme(project_path, project_name, security_mode, port)
    _create_agents_guide(project_path, project_name)
    _create_gitignore(project_path)
    _enhance_test_file(project_path, project_name)  # Do this before Pkg operations
    _add_mcprepl_dependency(project_path)

    println()
    println("✅ Project generated successfully!")
    println()
    println("📍 Next steps:")
    println("   1. cd $project_name")
    println("   2. julia --project=.")
    println("   3. The MCP server will start automatically!")
    println()
    println("🤖 For AI agents, see AGENTS.md in the project directory")
    println()

    return project_path
end

# ============================================================================
# Internal Helper Functions
# ============================================================================

function _create_security_config(project_path::String, mode::Symbol, port::Int)
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

function _create_startup_script(project_path::String, emoticon::String)
    println("📝 Creating Julia startup script...")

    startup_content = """
using Pkg
Pkg.activate(".")
import Base.Threads
using MCPRepl

# Load Revise for hot reloading (optional but recommended)
try
    using Revise
    @info "✓ Revise loaded - code changes will be tracked and auto-reloaded"
catch e
    @info "ℹ Revise not loaded (optional - install with: Pkg.add(\\"Revise\\"))"
end

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
end

function _create_vscode_config(project_path::String, mode::Symbol, port::Int)
    println("⚙️  Creating VS Code MCP configuration...")

    vscode_dir = joinpath(project_path, ".vscode")
    mkpath(vscode_dir)

    # Load security config to get API key if needed
    security_config_path = joinpath(project_path, ".mcprepl", "security.json")
    security_data = JSON.parsefile(security_config_path)
    api_keys = get(security_data, "api_keys", String[])

    # Build server config
    server_config = Dict{String,Any}("type" => "http", "url" => "http://localhost:$port")

    # Add Authorization header if not in lax mode
    if mode != :lax && !isempty(api_keys)
        server_config["headers"] =
            Dict{String,Any}("Authorization" => "Bearer $(first(api_keys))")
    end

    mcp_config = Dict("servers" => Dict("julia-repl" => server_config), "inputs" => [])

    mcp_path = joinpath(vscode_dir, "mcp.json")
    write(mcp_path, JSON.json(mcp_config, 2))

    # Set restrictive permissions if contains auth
    if haskey(server_config, "headers") && !Sys.iswindows()
        chmod(mcp_path, 0o600)
    end
end

function _create_vscode_settings(project_path::String)
    println("⚙️  Creating VS Code settings...")

    vscode_dir = joinpath(project_path, ".vscode")
    mkpath(vscode_dir)

    settings = Dict(
        "julia.environmentPath" => "\${workspaceFolder}",
        "julia.additionalArgs" => ["--load=\${workspaceFolder}/.julia-startup.jl"],
        "vscode-remote-control.allowedCommands" => [
            "language-julia.restartREPL",
            "language-julia.startREPL",
            "workbench.action.reloadWindow",
            "workbench.action.files.saveAll",
            "workbench.action.closeAllEditors",
            "workbench.action.terminal.focus",
            "workbench.action.focusActiveEditorGroup",
            "workbench.files.action.focusFilesExplorer",
            "workbench.action.quickOpen",
            "workbench.action.terminal.sendSequence",
            "workbench.action.tasks.runTask",
            "workbench.action.debug.start",
            "workbench.action.debug.stop",
            "workbench.action.debug.continue",
            "workbench.action.debug.stepOver",
            "workbench.action.debug.stepInto",
            "workbench.action.debug.stepOut",
            "editor.debug.action.toggleBreakpoint",
            "workbench.debug.action.focusVariablesView",
            "workbench.debug.action.focusWatchView",
            "workbench.action.debug.copyValue",
            "git.commit",
            "git.refresh",
            "git.sync",
            "search.action.openNewEditor",
            "editor.action.replaceAll",
            "workbench.action.splitEditor",
            "workbench.action.togglePanel",
            "workbench.action.toggleSidebarVisibility",
            "vscode.open",
            "workbench.action.gotoLine",
        ],
    )

    settings_path = joinpath(vscode_dir, "settings.json")
    write(settings_path, JSON.json(settings, 2))
end

function _create_claude_config_template(project_path::String, mode::Symbol, port::Int)
    println("🤖 Creating Claude Desktop config template...")

    # Load security config to get API key
    security_config_path = joinpath(project_path, ".mcprepl", "security.json")
    security_data = JSON.parsefile(security_config_path)
    api_keys = get(security_data, "api_keys", String[])

    config_template = if mode == :lax
        """
{
  "servers": {
    "julia-repl": {
      "type": "http",
      "url": "http://localhost:$port"
    }
  }
}
"""
    else
        """
{
  "servers": {
    "julia-repl": {
      "type": "http",
      "url": "http://localhost:$port",
      "headers": {
        "Authorization": "Bearer $(first(api_keys))"
      }
    }
  }
}
"""
    end

    template_path = joinpath(project_path, "claude-mcp-config.json")
    write(template_path, config_template)

    println("   ℹ️  To use with Claude Desktop, run:")
    if mode == :lax
        println("      claude mcp add julia-repl http://localhost:$port --transport http")
    else
        println(
            "      claude mcp add julia-repl http://localhost:$port --transport http \\",
        )
        println("        --header \"Authorization: Bearer $(first(api_keys))\"")
    end
end

function _create_gemini_config_template(project_path::String, mode::Symbol, port::Int)
    println("💎 Creating Gemini config template...")

    config_template = """
{
  "mcpServers": {
    "julia-repl": {
      "url": "http://localhost:$port"
    }
  }
}
"""

    template_path = joinpath(project_path, "gemini-settings.json")
    write(template_path, config_template)

    println("   ℹ️  Copy this to ~/.gemini/settings.json to use with Gemini")
end

function _create_readme(
    project_path::String,
    project_name::String,
    mode::Symbol,
    port::Int,
)
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
julia --project=.
```

The MCP server will start automatically when Julia launches!

## Project Structure

```
$project_name/
├── src/
│   └── $project_name.jl          # Main module
├── test/
│   └── runtests.jl                # Test suite
├── .mcprepl/
│   └── security.json              # Security configuration
├── .vscode/
│   ├── mcp.json                   # VS Code MCP config
│   └── settings.json              # VS Code settings
├── .julia-startup.jl              # Auto-starts MCP server
├── Project.toml                   # Package manifest
├── AGENTS.md                      # Guide for AI agents
└── README.md                      # This file
```

## Security Configuration

**Security Mode**: `$mode`
**Port**: `$port`
$(has_api_key ? "**API Key**: `$(first(api_keys))`\n\n⚠️  **Keep your API key secure!** Do not commit it to version control." : "**Authentication**: None (localhost only)")

### Security Modes

- **:lax** - Localhost only, no API key (development)
- **:relaxed** - API key required, any IP (testing)
- **:strict** - API key + IP allowlist (production)

To change security settings, edit `.mcprepl/security.json` or run:

```julia
using MCPRepl
MCPRepl.setup()  # Interactive wizard
```

## AI Agent Integration

### VS Code Copilot

Configuration is already set up in `.vscode/mcp.json`. Just:

1. Open this project in VS Code
2. Start Julia REPL
3. AI agents can now interact with your REPL!

### Claude Desktop

$(if has_api_key
    """
```bash
claude mcp add julia-repl http://localhost:$port \\
  --transport http \\
  --header "Authorization: Bearer $(first(api_keys))"
```
"""
else
    """
```bash
claude mcp add julia-repl http://localhost:$port --transport http
```
"""
end)

### Gemini

Copy `gemini-settings.json` to `~/.gemini/settings.json`

## Usage

### Running Tests

```julia
julia> using Pkg
julia> Pkg.test()
```

Or from the command line:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

### Adding Dependencies

```julia
julia> using Pkg
julia> Pkg.add("PackageName")
```

### Working with AI Agents

See [AGENTS.md](AGENTS.md) for detailed guidelines on how AI agents should interact with this project.

## Development

The project uses:

- **MCPRepl.jl** - Exposes REPL to AI agents via MCP protocol
- **Revise.jl** (optional) - Hot reloading of code changes

Install Revise for better development experience:

```julia
julia> using Pkg
julia> Pkg.add("Revise")
```

## Troubleshooting

### Server won't start

Check that port $port is available:

```bash
lsof -i :$port  # macOS/Linux
netstat -ano | findstr :$port  # Windows
```

Override port with environment variable:

```bash
JULIA_MCP_PORT=3001 julia --project=.
```

### Permission denied

On Unix systems, ports < 1024 require root. Use port ≥ 1024.

### API key authentication fails

Verify the API key in `.mcprepl/security.json` matches your client configuration.

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

function _create_gitignore(project_path::String)
    println("📝 Creating .gitignore...")

    gitignore_content = """
# Julia
*.jl.*.cov
*.jl.cov
*.jl.mem
/Manifest.toml
/docs/build/
/docs/site/

# MCPRepl
.mcprepl/
.julia-startup.jl

# VS Code
.vscode/
!.vscode/settings.json
!.vscode/mcp.json

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
        Pkg.activate(".")

        # Add MCPRepl (handles both registered and unregistered cases)
        try
            Pkg.add("MCPRepl")
        catch
            # If not registered, add from GitHub
            Pkg.add(url = "https://github.com/kahliburke/MCPRepl.jl")
        end

        # Add recommended development tools
        println("   Adding recommended development packages...")
        try
            Pkg.add("Revise")  # For hot reloading
        catch e
            @warn "Could not add Revise" exception = e
        end

        # Return to original environment
        Pkg.activate()
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
