using JSON

function get_vscode_workspace_mcp_path()
    # Look for .vscode/mcp.json in current directory
    vscode_dir = joinpath(pwd(), ".vscode")
    return joinpath(vscode_dir, "mcp.json")
end

function read_vscode_mcp_config()
    mcp_path = get_vscode_workspace_mcp_path()

    if !isfile(mcp_path)
        return nothing
    end

    try
        content = read(mcp_path, String)
        return JSON.parse(content; dicttype = Dict)
    catch
        return nothing
    end
end

function write_vscode_mcp_config(config::Dict)
    mcp_path = get_vscode_workspace_mcp_path()
    vscode_dir = dirname(mcp_path)

    # Create .vscode directory if it doesn't exist
    if !isdir(vscode_dir)
        mkdir(vscode_dir)
    end

    try
        # Pretty-print with 2-space indentation for readability
        content = JSON.json(config, 2)
        write(mcp_path, content)

        # Check if config contains API keys in Authorization headers
        has_auth_header = false
        if haskey(config, "servers")
            for (name, server_config) in config["servers"]
                if haskey(server_config, "headers") &&
                   haskey(server_config["headers"], "Authorization")
                    has_auth_header = true
                    break
                end
            end
        end

        # Set restrictive permissions if file contains sensitive data (Unix-like systems)
        if has_auth_header && !Sys.iswindows()
            chmod(mcp_path, 0o600)  # Read/write for owner only
        end

        return true
    catch e
        @warn "Failed to write VS Code config" exception = e
        return false
    end
end

function check_vscode_status()
    config = read_vscode_mcp_config()

    if config === nothing
        return :not_configured
    end

    servers = get(config, "servers", Dict())

    # Look for julia-repl or similar server
    for (name, server_config) in servers
        if contains(lowercase(string(name)), "julia")
            server_type = get(server_config, "type", "")
            if server_type == "http"
                return :configured_http
            elseif server_type == "stdio"
                return :configured_stdio
            else
                return :configured_unknown
            end
        end
    end

    return :not_configured
end

function add_vscode_mcp_server(_transport_type::String)
    # Load security config to get port and check if API key is required
    security_config = load_security_config()

    if security_config === nothing
        @warn "No security configuration found. Run MCPRepl.setup() first."
        return false
    end

    # Use Generate module's shared function
    return Generate.create_vscode_config(
        pwd(),
        security_config.port,
        security_config.mode == :lax ? nothing :
        isempty(security_config.api_keys) ? nothing : first(security_config.api_keys),
    )
end

function remove_vscode_mcp_server()
    config = read_vscode_mcp_config()

    if config === nothing
        return true  # Nothing to remove
    end

    servers = get(config, "servers", Dict())

    # Remove any Julia-related server
    for name in collect(keys(servers))
        if contains(lowercase(string(name)), "julia")
            delete!(servers, name)
        end
    end

    config["servers"] = servers
    return write_vscode_mcp_config(config)
end

# ============================================================================
# Claude Code Configuration (~/.claude.json project-level config)
# ============================================================================

function get_claude_config_path()
    return expanduser("~/.claude.json")
end

function read_claude_config()
    config_path = get_claude_config_path()

    if !isfile(config_path)
        return nothing
    end

    try
        content = read(config_path, String)
        return JSON.parse(content; dicttype = Dict)
    catch
        return nothing
    end
end

function write_claude_config(config::Dict)
    config_path = get_claude_config_path()

    try
        # Pretty-print Claude project config with 2-space indentation
        content = JSON.json(config, 2)
        write(config_path, content)

        # Set restrictive permissions (Unix-like systems)
        if !Sys.iswindows()
            chmod(config_path, 0o600)  # Read/write for owner only
        end

        return true
    catch e
        @warn "Failed to write Claude config" exception = e
        return false
    end
end

function add_claude_mcp_server(; api_key::Union{String,Nothing} = nothing)
    # Load security config to get port and API key
    security_config = load_security_config()

    if security_config === nothing
        @warn "No security configuration found. Run MCPRepl.setup() first."
        return false
    end

    port = security_config.port
    url = "http://localhost:$port"

    # Use claude mcp add command instead of manipulating JSON directly
    # Use --scope=project because the REPL and port config are local to the project
    try
        # Determine REPL target ID (same logic as in start!)
        repl_id = basename(pwd())

        if api_key !== nothing
            # Add with Authorization and target headers using -H flag
            run(
                `claude mcp add julia-repl $url --scope project --transport http -H "Authorization: Bearer $api_key" -H "X-MCPRepl-Target: $repl_id"`,
            )
        else
            # Add with target header (for lax mode)
            run(
                `claude mcp add julia-repl $url --scope project --transport http -H "X-MCPRepl-Target: $repl_id"`,
            )
        end
        return true
    catch e
        @warn "Failed to configure Claude MCP server" exception = e
        return false
    end
end

function remove_claude_mcp_server()
    # Use claude mcp remove command instead of manipulating JSON directly
    # Use --scope=project to match how the server was added
    try
        run(`claude mcp remove --scope project julia-repl`)
        return true
    catch e
        # If command fails, it might be because the server doesn't exist
        # which is fine - we wanted it removed anyway
        if occursin("not found", string(e)) || occursin("does not exist", string(e))
            return true
        end
        @warn "Failed to remove Claude MCP server" exception = e
        return false
    end
end

# ============================================================================
# VS Code Settings
# ============================================================================

function get_vscode_settings_path()
    vscode_dir = joinpath(pwd(), ".vscode")
    return joinpath(vscode_dir, "settings.json")
end

function read_vscode_settings()
    settings_path = get_vscode_settings_path()

    if !isfile(settings_path)
        return Dict()
    end

    try
        content = read(settings_path, String)
        # Handle JSON with comments (JSONC)
        lines = split(content, '\n')
        cleaned_lines = filter(line -> !startswith(strip(line), "//"), lines)
        cleaned_content = join(cleaned_lines, '\n')
        return JSON.parse(cleaned_content; dicttype = Dict)
    catch e
        @warn "Failed to read VS Code settings.json" exception = e
        return Dict()
    end
end

function write_vscode_settings(settings::Dict)
    settings_path = get_vscode_settings_path()
    vscode_dir = dirname(settings_path)

    # Create .vscode directory if it doesn't exist
    if !isdir(vscode_dir)
        mkdir(vscode_dir)
    end

    try
        # Pretty print VS Code settings with 2-space indentation
        content = JSON.json(settings, 2)
        write(settings_path, content)
        return true
    catch e
        @warn "Failed to write VS Code settings.json" exception = e
        return false
    end
end

function get_startup_script_path()
    return joinpath(pwd(), ".julia-startup.jl")
end

function has_startup_script()
    return isfile(get_startup_script_path())
end

function install_startup_script(; emoticon::String = "🐉")
    startup_path = get_startup_script_path()

    # Load security config to get port if available
    security_config = load_security_config()
    port = security_config !== nothing ? security_config.port : 3000

    # Use Generate module's shared function
    return Generate.create_startup_script(dirname(startup_path), port, emoticon)
end

function install_repl_script()
    """Install the repl launcher script in the current workspace"""
    return Generate.create_repl_script(pwd())
end

function install_env_file()
    """Create a project `.env` file from the security configuration."""
    security_config = load_security_config()
    port = security_config !== nothing ? security_config.port : 3000
    api_key = nothing
    if security_config !== nothing && !isempty(security_config.api_keys)
        api_key = first(security_config.api_keys)
    end
    return Generate.create_env_file(pwd(), port, api_key)
end

function install_claude_settings()
    """Create .claude/settings.json with environment variables for Claude."""
    security_config = load_security_config()
    api_key = nothing
    if security_config !== nothing && !isempty(security_config.api_keys)
        api_key = first(security_config.api_keys)
    end
    return Generate.create_claude_env_settings(pwd(), api_key)
end

function configure_vscode_julia_args()
    settings = read_vscode_settings()
    startup_path = get_startup_script_path()
    load_arg = "--load=\${workspaceFolder}/.julia-startup.jl"

    # Get or create julia.additionalArgs array
    if !haskey(settings, "julia.additionalArgs")
        settings["julia.additionalArgs"] = []
    end

    args = settings["julia.additionalArgs"]

    # Check if the load argument is already present
    has_load_arg =
        any(arg -> contains(arg, "--load") && contains(arg, ".julia-startup.jl"), args)

    if !has_load_arg
        push!(args, load_arg)
        settings["julia.additionalArgs"] = args
        return write_vscode_settings(settings)
    end

    return true  # Already configured
end

function check_vscode_startup_configured()
    settings = read_vscode_settings()

    if !haskey(settings, "julia.additionalArgs")
        return false
    end

    args = settings["julia.additionalArgs"]
    return any(arg -> contains(arg, "--load") && contains(arg, ".julia-startup.jl"), args)
end

function check_vscode_extension_installed()
    """Check if the VS Code Remote Control extension is installed"""
    ext_dir = vscode_extensions_dir()
    # Check for any version of the extension
    try
        entries = readdir(ext_dir)
        return any(entry -> startswith(entry, "MCPRepl.vscode-remote-control"), entries)
    catch
        return false
    end
end

function prompt_and_setup_vscode_startup(; gentle::Bool = false)
    """Prompt user to install startup script and configure VS Code settings"""

    emoticon = gentle ? "🦋" : "🐉"
    has_script = has_startup_script()
    has_args = check_vscode_startup_configured()

    # If everything is already configured, skip
    if has_script && has_args
        return true
    end

    println()
    println("📝 Julia Startup Script Configuration")
    println()
    println("   For automatic MCP server startup when Julia REPL starts,")
    println("   we can install a .julia-startup.jl script and configure")
    println("   VS Code to load it automatically.")
    println()

    if has_script
        println("   ✓ Startup script already exists: .julia-startup.jl")
    else
        println("   • Will create: .julia-startup.jl")
    end

    if has_args
        println("   ✓ VS Code already configured to load startup script")
    else
        println("   • Will update: .vscode/settings.json")
        println("     (adds --load flag to julia.additionalArgs)")
    end

    println()
    print("   Install and configure startup script? [Y/n]: ")
    response = strip(lowercase(readline()))

    # Default to yes
    if isempty(response) || response == "y" || response == "yes"
        success = true

        # Install startup script if needed
        if !has_script
            if install_startup_script(emoticon = emoticon)
                println("   ✅ Created .julia-startup.jl")
            else
                println("   ❌ Failed to create .julia-startup.jl")
                success = false
            end
        end

        # Also install the repl launcher script
        if install_repl_script()
            println("   ✅ Created repl launcher script")
        else
            println("   ⚠️  Failed to create repl launcher script (optional)")
        end

        # Create project .env file from security config
        if install_env_file()
            println("   ✅ Created .env file")
        else
            println("   ⚠️  Failed to create .env file (optional)")
        end

        # Create Claude settings file (.claude/settings.json)
        if install_claude_settings()
            println("   ✅ Created .claude/settings.json for Claude")
        else
            println("   ⚠️  Failed to create .claude/settings.json (optional)")
        end

        # Configure VS Code settings if needed
        if !has_args
            if configure_vscode_julia_args()
                println("   ✅ Updated .vscode/settings.json")
            else
                println("   ❌ Failed to update .vscode/settings.json")
                success = false
            end
        end

        if success
            println()
            println("   💡 Restart Julia REPL to use the startup script")
        end

        return success
    else
        println("   ⏭️  Skipped startup script configuration")
        return true
    end
end

function prompt_and_setup_vscode_extension()
    """Prompt user to install VS Code Remote Control extension"""

    has_extension = check_vscode_extension_installed()

    println()
    println("📝 VS Code Remote Control Extension")
    println()

    if has_extension
        println("   ✓ Extension already installed")
        print("   Reinstall VS Code Remote Control extension? [Y/n]: ")
    else
        println("   For REPL restart functionality via MCP tools, we can install")
        println("   a VS Code extension that allows the MCP server to trigger")
        println("   VS Code commands like restarting the Julia REPL.")
        println()
        print("   Install VS Code Remote Control extension? [Y/n]: ")
    end

    response = strip(lowercase(readline()))

    # Default to yes
    if isempty(response) || response == "y" || response == "yes"
        try
            # Install the extension with Julia REPL commands allowed
            # This will remove old versions first
            install_vscode_remote_control(
                pwd();
                allowed_commands = [
                    # REPL & Window Control
                    "language-julia.startREPL",
                    "workbench.action.reloadWindow",

                    # File Operations
                    "workbench.action.files.saveAll",
                    "workbench.action.closeAllEditors",
                    "workbench.action.files.openFile",
                    "vscode.open",
                    "vscode.openWith",

                    # Navigation & Focus
                    "workbench.action.terminal.focus",
                    "workbench.action.focusActiveEditorGroup",
                    "workbench.files.action.focusFilesExplorer",
                    "workbench.action.quickOpen",
                    "workbench.action.gotoLine",
                    "workbench.action.navigateToLastEditLocation",
                    "editor.action.goToLocations",
                    "workbench.action.showAllSymbols",

                    # LSP / Editor Actions (useful for code navigation, refactor, and formatting)
                    "editor.action.rename",
                    "editor.action.formatDocument",
                    "editor.action.organizeImports",
                    "editor.action.codeAction",
                    "editor.action.quickFix",
                    "editor.action.referenceSearch.trigger",
                    "editor.action.goToImplementation",
                    "editor.action.peekImplementation",
                    "editor.action.goToTypeDefinition",
                    "editor.action.showHover",

                    # Terminal Operations
                    "workbench.action.terminal.new",
                    "workbench.action.terminal.sendSequence",
                    "workbench.action.terminal.kill",

                    # Testing - VS Code Test Explorer
                    "testing.runAll",
                    "testing.runCurrentFile",
                    "testing.runAtCursor",
                    "testing.reRunFailedTests",
                    "testing.reRunLastRun",
                    "testing.cancelRun",
                    "testing.debugAll",
                    "testing.debugCurrentFile",
                    "testing.debugAtCursor",
                    "testing.showMostRecentOutput",
                    "testing.openOutputPeek",
                    "testing.toggleTestingView",
                    "workbench.view.testing.focus",

                    # Testing & Debugging - Basic Controls
                    "workbench.action.tasks.runTask",
                    "workbench.action.debug.start",
                    "workbench.action.debug.run",
                    "workbench.action.debug.stop",
                    "workbench.action.debug.restart",
                    "workbench.action.debug.pause",
                    "workbench.action.debug.continue",

                    # Debugger - Stepping
                    "workbench.action.debug.stepOver",
                    "workbench.action.debug.stepInto",
                    "workbench.action.debug.stepOut",
                    "workbench.action.debug.stepBack",

                    # Debugger - Breakpoints
                    "editor.debug.action.toggleBreakpoint",
                    "editor.debug.action.conditionalBreakpoint",
                    "editor.debug.action.toggleInlineBreakpoint",
                    "workbench.debug.viewlet.action.removeAllBreakpoints",
                    "workbench.debug.viewlet.action.enableAllBreakpoints",
                    "workbench.debug.viewlet.action.disableAllBreakpoints",

                    # Debugger - Views & Panels
                    "workbench.view.debug",
                    "workbench.debug.action.focusVariablesView",
                    "workbench.debug.action.focusWatchView",
                    "workbench.debug.action.focusCallStackView",
                    "workbench.debug.action.focusBreakpointsView",

                    # Debugger - Watch & Variables
                    "workbench.debug.viewlet.action.addFunctionBreakpoint",
                    "workbench.action.debug.addWatch",
                    "workbench.action.debug.removeWatch",
                    "workbench.debug.action.copyValue",

                    # Git Operations
                    "git.commit",
                    "git.refresh",
                    "git.sync",
                    "git.branchFrom",
                    "git.pull",
                    "git.push",
                    "git.fetch",

                    # Search & Replace
                    "workbench.action.findInFiles",
                    "workbench.action.replaceInFiles",

                    # Window Management
                    "workbench.action.splitEditor",
                    "workbench.action.togglePanel",
                    "workbench.action.toggleSidebarVisibility",

                    # Extension Management
                    "workbench.extensions.installExtension",
                ],
                require_confirmation = false,
            )
            if has_extension
                println("   ✅ Reinstalled VS Code Remote Control extension")
            else
                println("   ✅ Installed VS Code Remote Control extension")
            end
            println("   ✅ Configured allowed commands")
            println()
            println("   💡 Reload VS Code window to activate the extension")
            return true
        catch e
            println("   ❌ Failed to install extension: $e")
            return false
        end
    else
        println("   ⏭️  Skipped extension installation")
        if !has_extension
            println("   💡 Note: restart_repl tool will not work without this extension")
        end
        return true
    end
end

function check_claude_status()
    # Check if claude command exists (cross-platform)
    try
        # Use success() to check if command exists and runs without error
        # Redirect both stdout and stderr to devnull
        if !success(pipeline(`claude --version`, stdout = devnull, stderr = devnull))
            return :claude_not_found
        end
    catch
        # Command not found or failed to execute
        return :claude_not_found
    end

    # Check if MCP server is already configured
    try
        output = read(`claude mcp list`, String)
        if contains(output, "julia-repl")
            # Detect transport method
            if contains(output, "http://localhost")
                return :configured_http
            elseif contains(output, "mcp-julia-adapter")
                return :configured_script
            else
                return :configured_unknown
            end
        else
            return :not_configured
        end
    catch
        return :not_configured
    end
end

function get_gemini_settings_path()
    homedir = expanduser("~")
    gemini_dir = joinpath(homedir, ".gemini")
    settings_path = joinpath(gemini_dir, "settings.json")
    return gemini_dir, settings_path
end

function read_gemini_settings()
    gemini_dir, settings_path = get_gemini_settings_path()

    if !isfile(settings_path)
        return Dict()
    end

    try
        content = read(settings_path, String)
        return JSON.parse(content; dicttype = Dict)
    catch
        return Dict()
    end
end

function write_gemini_settings(settings::Dict)
    gemini_dir, settings_path = get_gemini_settings_path()

    # Create .gemini directory if it doesn't exist
    if !isdir(gemini_dir)
        mkdir(gemini_dir)
    end

    try
        # Pretty-print Gemini settings with 2-space indentation
        content = JSON.json(settings, 2)
        write(settings_path, content)
        return true
    catch
        return false
    end
end

function check_gemini_status()
    # Check if gemini command exists (cross-platform)
    try
        # Use success() to check if command exists and runs without error
        if !success(pipeline(`gemini --version`, stdout = devnull, stderr = devnull))
            return :gemini_not_found
        end
    catch
        # Command not found or failed to execute
        return :gemini_not_found
    end

    # Check if MCP server is configured in settings.json
    settings = read_gemini_settings()
    mcp_servers = get(settings, "mcpServers", Dict())

    if haskey(mcp_servers, "julia-repl")
        server_config = mcp_servers["julia-repl"]
        if haskey(server_config, "url") &&
           contains(server_config["url"], "http://localhost")
            return :configured_http
        elseif haskey(server_config, "command")
            return :configured_script
        else
            return :configured_unknown
        end
    else
        return :not_configured
    end
end

function add_gemini_mcp_server(transport_type::String)
    # Load security config to get port
    security_config = load_security_config()

    if security_config === nothing
        @warn "No security configuration found. Run MCPRepl.setup() first."
        return false
    end

    port = security_config.port

    settings = read_gemini_settings()

    if !haskey(settings, "mcpServers")
        settings["mcpServers"] = Dict()
    end

    if transport_type == "http"
        settings["mcpServers"]["julia-repl"] = Dict("url" => "http://localhost:$port")
    elseif transport_type == "script"
        settings["mcpServers"]["julia-repl"] =
            Dict("command" => "$(pkgdir(MCPRepl))/mcp-julia-adapter")
    else
        return false
    end

    return write_gemini_settings(settings)
end

function remove_gemini_mcp_server()
    settings = read_gemini_settings()

    if haskey(settings, "mcpServers") && haskey(settings["mcpServers"], "julia-repl")
        delete!(settings["mcpServers"], "julia-repl")
        return write_gemini_settings(settings)
    end

    return true  # Already removed
end

"""
    setup()

Interactive setup wizard for configuring MCP servers across different clients.

Port configuration is handled during the security setup wizard and stored in
`.mcprepl/security.json`. The port can be overridden at runtime using the
`JULIA_MCP_PORT` environment variable.

# Supported Clients
- **VS Code Copilot**: Configures `.vscode/mcp.json` in the current workspace
  - Optionally installs `.julia-startup.jl` for automatic MCP server startup
  - Configures `.vscode/settings.json` to load the startup script
- **Claude Code CLI**: Configures via `claude mcp` commands (if available)
- **Gemini CLI**: Configures `~/.gemini/settings.json` (if available)

# Transport Types
- **HTTP**: Direct connection to Julia HTTP server (recommended, simpler)
- **stdio**: Via Python adapter script (for compatibility with some clients)

# VS Code Startup Script
When configuring VS Code, the setup wizard will offer to:
1. Create `.julia-startup.jl` that automatically starts the MCP server
2. Update `.vscode/settings.json` to load the startup script via `--load` flag

This enables seamless MCP server startup whenever you start a Julia REPL in VS Code.

# Examples
```julia
# Interactive setup (port configured during security setup)
MCPRepl.setup()

# Override port at runtime with environment variable
ENV["JULIA_MCP_PORT"] = "3001"
MCPRepl.start!()
```

# Notes
After configuring VS Code, reload the window (Cmd+Shift+P → "Reload Window")
to apply changes. If you installed the startup script, restart your Julia REPL
to see it in action.
"""
function setup(; gentle::Bool = false)
    # FIRST: Check security configuration
    security_config = load_security_config()

    if security_config === nothing
        printstyled(
            "\n╔═══════════════════════════════════════════════════════════╗\n",
            color = :cyan,
            bold = true,
        )
        printstyled(
            "║                                                           ║\n",
            color = :cyan,
            bold = true,
        )
        printstyled(
            "║         🔒 MCPRepl Security Setup Required 🔒             ║\n",
            color = :yellow,
            bold = true,
        )
        printstyled(
            "║                                                           ║\n",
            color = :cyan,
            bold = true,
        )
        printstyled(
            "╚═══════════════════════════════════════════════════════════╝\n",
            color = :cyan,
            bold = true,
        )
        println()
        println("MCPRepl now requires security configuration before use.")
        println("This includes API key authentication and IP allowlisting.")
        println()
        print("Run security setup wizard now? [Y/n]: ")
        response = strip(lowercase(readline()))

        if isempty(response) || response == "y" || response == "yes"
            security_config = security_setup_wizard(pwd(); gentle = gentle)
            println()
            printstyled("✅ Security configuration complete!\n", color = :green, bold = true)
            println()
        else
            println()
            printstyled(
                "⚠️  Setup incomplete. Run MCPRepl.setup_security() later.\n",
                color = :yellow,
            )
            println()
            return
        end
    else
        printstyled(
            "\n✅ Security configured (mode: $(security_config.mode))\n",
            color = :green,
        )
        println()
    end

    # Install/update startup script
    emoticon = gentle ? "🦋" : "🐉"
    if !has_startup_script()
        println("📝 Installing Julia startup script...")
        if install_startup_script(emoticon = emoticon)
            println("   ✅ Created .julia-startup.jl")
        else
            println("   ❌ Failed to create .julia-startup.jl")
        end
    else
        println("📝 Startup script: ✅ .julia-startup.jl exists")
    end

    # Configure VS Code settings for startup script
    if !check_vscode_startup_configured()
        println("📝 Configuring VS Code to load startup script...")
        if configure_vscode_julia_args()
            println("   ✅ Updated .vscode/settings.json")
        else
            println("   ❌ Failed to update .vscode/settings.json")
        end
    else
        println("📝 VS Code settings: ✅ Configured to load startup script")
    end
    println()

    # Get port from security config (can be overridden by ENV var when server starts)
    port = security_config.port

    claude_status = check_claude_status()
    gemini_status = check_gemini_status()
    vscode_status = check_vscode_status()

    # Show current status
    println("🚀 Server Configuration")
    println("   Port: $port")
    println()

    # VS Code status
    if vscode_status == :configured_http
        println("📊 VS Code status: ✅ MCP server configured (HTTP transport)")
    elseif vscode_status == :configured_stdio
        println("📊 VS Code status: ✅ MCP server configured (stdio transport)")
    elseif vscode_status == :configured_unknown
        println("📊 VS Code status: ✅ MCP server configured (unknown transport)")
    else
        println("📊 VS Code status: ❌ MCP server not configured")
    end

    # Claude status
    if claude_status == :claude_not_found
        println("📊 Claude status: ❌ Claude Code not found in PATH")
    elseif claude_status == :configured_http
        println("📊 Claude status: ✅ MCP server configured (HTTP transport)")
    elseif claude_status == :configured_script
        println("📊 Claude status: ✅ MCP server configured (script transport)")
    elseif claude_status == :configured_unknown
        println("📊 Claude status: ✅ MCP server configured (unknown transport)")
    else
        println("📊 Claude status: ❌ MCP server not configured")
    end

    # Gemini status
    if gemini_status == :gemini_not_found
        println("📊 Gemini status: ❌ Gemini CLI not found in PATH")
    elseif gemini_status == :configured_http
        println("📊 Gemini status: ✅ MCP server configured (HTTP transport)")
    elseif gemini_status == :configured_script
        println("📊 Gemini status: ✅ MCP server configured (script transport)")
    elseif gemini_status == :configured_unknown
        println("📊 Gemini status: ✅ MCP server configured (unknown transport)")
    else
        println("📊 Gemini status: ❌ MCP server not configured")
    end
    println()

    # Show options
    println("Available actions:")

    # VS Code options
    println("   VS Code Copilot:")
    if vscode_status in [:configured_http, :configured_stdio, :configured_unknown]
        println("     [1] Remove VS Code MCP configuration")
        println("     [2] Add/Replace with HTTP transport (recommended)")
        println("     [3] Add/Replace with stdio transport (adapter)")
    else
        println("     [1] Add HTTP transport (recommended)")
        println("     [2] Add stdio transport (adapter)")
    end

    # Claude options
    if claude_status != :claude_not_found
        println("   Claude Code:")
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            println("     [4] Remove Claude MCP configuration")
            println("     [5] Add/Replace Claude with HTTP transport")
            println("     [6] Add/Replace Claude with script transport")
        else
            println("     [4] Add Claude HTTP transport")
            println("     [5] Add Claude script transport")
        end
    end

    # Gemini options
    if gemini_status != :gemini_not_found
        println("   Gemini CLI:")
        if gemini_status in [:configured_http, :configured_script, :configured_unknown]
            println("     [7] Remove Gemini MCP configuration")
            println("     [8] Add/Replace Gemini with HTTP transport")
            println("     [9] Add/Replace Gemini with script transport")
        else
            println("     [7] Add Gemini HTTP transport")
            println("     [8] Add Gemini script transport")
        end
    end

    println()
    print("   Enter choice: ")

    choice = readline()

    # Handle choice
    if choice == "1"
        if vscode_status in [:configured_http, :configured_stdio, :configured_unknown]
            println("\n   Removing VS Code MCP configuration...")
            if remove_vscode_mcp_server()
                println("   ✅ Successfully removed VS Code MCP configuration")
                println("   💡 Reload VS Code window to apply changes")
            else
                println("   ❌ Failed to remove VS Code MCP configuration")
            end
        else
            println("\n   Adding VS Code HTTP transport...")
            if add_vscode_mcp_server("http")
                println("   ✅ Successfully configured VS Code HTTP transport")
                println("   🌐 Server URL: http://localhost:$port")

                # Prompt for startup script installation
                prompt_and_setup_vscode_startup(gentle = gentle)

                # Prompt for VS Code extension installation
                prompt_and_setup_vscode_extension()

                println()
                println("   🔄 Reload VS Code window to apply changes")
            else
                println("   ❌ Failed to configure VS Code HTTP transport")
            end
        end
    elseif choice == "2"
        if vscode_status in [:configured_http, :configured_stdio, :configured_unknown]
            println("\n   Adding/Replacing VS Code with HTTP transport...")
            if add_vscode_mcp_server("http")
                println("   ✅ Successfully configured VS Code HTTP transport")
                println("   🌐 Server URL: http://localhost:$port")

                # Prompt for startup script installation
                prompt_and_setup_vscode_startup(gentle = gentle)

                # Prompt for VS Code extension installation
                prompt_and_setup_vscode_extension()

                println()
                println("   🔄 Reload VS Code window to apply changes")
            else
                println("   ❌ Failed to configure VS Code HTTP transport")
            end
        else
            println("\n   Adding VS Code stdio transport...")
            if add_vscode_mcp_server("stdio")
                println("   ✅ Successfully configured VS Code stdio transport")

                # Prompt for startup script installation
                prompt_and_setup_vscode_startup(gentle = gentle)

                # Prompt for VS Code extension installation
                prompt_and_setup_vscode_extension()

                println()
                println("   💡 Reload VS Code window to apply changes")
            else
                println("   ❌ Failed to configure VS Code stdio transport")
            end
        end
    elseif choice == "3"
        if vscode_status in [:configured_http, :configured_stdio, :configured_unknown]
            println("\n   Adding/Replacing VS Code with stdio transport...")
            if add_vscode_mcp_server("stdio")
                println("   ✅ Successfully configured VS Code stdio transport")

                # Prompt for startup script installation
                prompt_and_setup_vscode_startup(gentle = gentle)

                # Prompt for VS Code extension installation
                prompt_and_setup_vscode_extension()

                println()
                println("   💡 Reload VS Code window to apply changes")
            else
                println("   ❌ Failed to configure VS Code stdio transport")
            end
        end
    elseif choice == "4"
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Removing Claude MCP configuration...")
            try
                run(`claude mcp remove --scope project julia-repl`)
                println("   ✅ Successfully removed Claude MCP configuration")
            catch e
                println("   ❌ Failed to remove Claude MCP configuration: $e")
            end
        elseif claude_status != :claude_not_found
            println("\n   Adding Claude HTTP transport...")
            try
                # Add Authorization header if not in lax mode
                repl_id = basename(pwd())
                if security_config.mode != :lax && !isempty(security_config.api_keys)
                    api_key = first(security_config.api_keys)
                    run(
                        `claude mcp add julia-repl http://localhost:$port --scope project --transport http -H "Authorization: Bearer $api_key" -H "X-MCPRepl-Target: $repl_id"`,
                    )
                else
                    run(
                        `claude mcp add julia-repl http://localhost:$port --scope project --transport http -H "X-MCPRepl-Target: $repl_id"`,
                    )
                end
                println("   ✅ Successfully configured Claude HTTP transport")
            catch e
                println("   ❌ Failed to configure Claude HTTP transport: $e")
            end
        end
    elseif choice == "5"
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Adding/Replacing Claude with HTTP transport...")
            try
                # Add Authorization header if not in lax mode
                if security_config.mode != :lax && !isempty(security_config.api_keys)
                    api_key = first(security_config.api_keys)
                    run(
                        `claude mcp add julia-repl http://localhost:$port --scope project --transport http -H "Authorization: Bearer $api_key"`,
                    )
                else
                    run(
                        `claude mcp add julia-repl http://localhost:$port --scope project --transport http`,
                    )
                end
                println("   ✅ Successfully configured Claude HTTP transport")
            catch e
                println("   ❌ Failed to configure Claude HTTP transport: $e")
            end
        elseif claude_status != :claude_not_found
            adapter_path = joinpath(pkgdir(MCPRepl), "mcp-julia-adapter")
            println("\n   Adding Claude script transport...")
            try
                run(`claude mcp add julia-repl $adapter_path --scope project`)
                println("   ✅ Successfully configured Claude script transport")
            catch e
                println("   ❌ Failed to configure Claude script transport: $e")
            end
        end
    elseif choice == "6"
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            adapter_path = joinpath(pkgdir(MCPRepl), "mcp-julia-adapter")
            println("\n   Adding/Replacing Claude with script transport...")
            try
                run(`claude mcp add julia-repl $adapter_path --scope project`)
                println("   ✅ Successfully configured Claude script transport")
            catch e
                println("   ❌ Failed to configure Claude script transport: $e")
            end
        end
    elseif choice == "7"
        if gemini_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Removing Gemini MCP configuration...")
            if remove_gemini_mcp_server()
                println("   ✅ Successfully removed Gemini MCP configuration")
            else
                println("   ❌ Failed to remove Gemini MCP configuration")
            end
        elseif gemini_status != :gemini_not_found
            println("\n   Adding Gemini HTTP transport...")
            if add_gemini_mcp_server("http")
                println("   ✅ Successfully configured Gemini HTTP transport")
            else
                println("   ❌ Failed to configure Gemini HTTP transport")
            end
        end
    elseif choice == "8"
        if gemini_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Adding/Replacing Gemini with HTTP transport...")
            if add_gemini_mcp_server("http")
                println("   ✅ Successfully configured Gemini HTTP transport")
            else
                println("   ❌ Failed to configure Gemini HTTP transport")
            end
        elseif gemini_status != :gemini_not_found
            println("\n   Adding Gemini script transport...")
            if add_gemini_mcp_server("script")
                println("   ✅ Successfully configured Gemini script transport")
            else
                println("   ❌ Failed to configure Gemini script transport")
            end
        end
    elseif choice == "9"
        if gemini_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Adding/Replacing Gemini with script transport...")
            if add_gemini_mcp_server("script")
                println("   ✅ Successfully configured Gemini script transport")
            else
                println("   ❌ Failed to configure Gemini script transport")
            end
        end
    else
        println("\n   Invalid choice. Please run MCPRepl.setup() again.")
        return
    end

    println("   💡 HTTP for direct connection, script for agent compatibility")
end

"""
    reset(; workspace_dir::String=pwd())

Reset MCPRepl configuration by removing all generated files and configurations.
This includes:
- .mcprepl/ directory (security config, API keys)
- .julia-startup.jl script
- VS Code settings modifications (julia.additionalArgs)
- MCP server configurations from .vscode/mcp.json

Use this to start fresh with a clean setup.
"""
function reset(; workspace_dir::String = pwd())
    println()
    printstyled("⚠️  MCPRepl Configuration Reset\n", color = :yellow, bold = true)
    println()
    println("This will remove:")
    println("  • .mcprepl/ directory (security config and API keys)")
    println("  • .julia-startup.jl script")
    println("  • VS Code Julia startup configuration")
    println("  • MCP server entries from .vscode/mcp.json")
    println()
    print("Are you sure you want to reset? [y/N]: ")
    response = strip(lowercase(readline()))

    if !(response == "y" || response == "yes")
        println()
        println("Reset cancelled.")
        return false
    end

    println()
    success_count = 0
    total_count = 0

    # Remove .mcprepl directory
    total_count += 1
    mcprepl_dir = joinpath(workspace_dir, ".mcprepl")
    if isdir(mcprepl_dir)
        try
            rm(mcprepl_dir; recursive = true, force = true)
            println("✅ Removed .mcprepl/ directory")
            success_count += 1
        catch e
            println("❌ Failed to remove .mcprepl/: $e")
        end
    else
        println("ℹ️  .mcprepl/ directory not found (already clean)")
        success_count += 1
    end

    # Remove .julia-startup.jl
    total_count += 1
    startup_script = joinpath(workspace_dir, ".julia-startup.jl")
    if isfile(startup_script)
        try
            rm(startup_script; force = true)
            println("✅ Removed .julia-startup.jl")
            success_count += 1
        catch e
            println("❌ Failed to remove .julia-startup.jl: $e")
        end
    else
        println("ℹ️  .julia-startup.jl not found (already clean)")
        success_count += 1
    end

    # Remove VS Code julia.additionalArgs configuration
    total_count += 1
    vscode_settings_path = joinpath(workspace_dir, ".vscode", "settings.json")
    if isfile(vscode_settings_path)
        try
            settings = JSON.parsefile(vscode_settings_path; dicttype = Dict{String,Any})

            if haskey(settings, "julia.additionalArgs")
                args = settings["julia.additionalArgs"]
                # Remove --load argument
                filter!(
                    arg -> !(contains(arg, "--load") && contains(arg, ".julia-startup.jl")),
                    args,
                )

                # If array is now empty, remove the key entirely
                if isempty(args)
                    delete!(settings, "julia.additionalArgs")
                else
                    settings["julia.additionalArgs"] = args
                end

                # Write back
                open(vscode_settings_path, "w") do io
                    JSON.print(io, settings, 2)
                end
                println("✅ Removed Julia startup config from VS Code settings")
                success_count += 1
            else
                println("ℹ️  No Julia startup config in VS Code settings (already clean)")
                success_count += 1
            end
        catch e
            println("❌ Failed to update VS Code settings: $e")
        end
    else
        println("ℹ️  .vscode/settings.json not found (already clean)")
        success_count += 1
    end

    # Remove MCP server entries from .vscode/mcp.json
    total_count += 1
    mcp_config_path = joinpath(workspace_dir, ".vscode", "mcp.json")
    if isfile(mcp_config_path)
        try
            mcp_config = JSON.parsefile(mcp_config_path; dicttype = Dict{String,Any})

            if haskey(mcp_config, "servers")
                servers = mcp_config["servers"]
                # Remove julia-repl server entries
                removed = false
                if haskey(servers, "julia-repl")
                    delete!(servers, "julia-repl")
                    removed = true
                end

                if removed
                    # Write back
                    open(mcp_config_path, "w") do io
                        JSON.print(io, mcp_config, 2)
                    end
                    println("✅ Removed MCPRepl server from .vscode/mcp.json")
                    success_count += 1
                else
                    println("ℹ️  No MCPRepl server in .vscode/mcp.json (already clean)")
                    success_count += 1
                end
            else
                println("ℹ️  No servers in .vscode/mcp.json (already clean)")
                success_count += 1
            end
        catch e
            println("❌ Failed to update .vscode/mcp.json: $e")
        end
    else
        println("ℹ️  .vscode/mcp.json not found (already clean)")
        success_count += 1
    end

    println()
    if success_count == total_count
        printstyled(
            "✅ Reset complete! All MCPRepl files removed.\n",
            color = :green,
            bold = true,
        )
        println()
        println("Run MCPRepl.setup() to configure again.")
    else
        printstyled(
            "⚠️  Reset completed with some errors ($success_count/$total_count successful)\n",
            color = :yellow,
            bold = true,
        )
    end
    println()

    return success_count == total_count
end
