using JSON

function check_claude_status()
    # Check if claude command exists
    try
        run(pipeline(`which claude`, devnull))
    catch
        return :claude_not_found
    end

    # Check if MCP server is already configured
    try
        output = read(`claude mcp list`, String)
        if contains(output, "julia-repl")
            # Detect transport method
            if contains(output, "http://localhost:3000")
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
        return JSON.parse(content)
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
        content = JSON.json(settings, 4)
        write(settings_path, content)
        return true
    catch
        return false
    end
end

function check_gemini_status()
    # Check if gemini command exists
    try
        run(pipeline(`which gemini`, devnull))
    catch
        return :gemini_not_found
    end

    # Check if MCP server is configured in settings.json
    settings = read_gemini_settings()
    mcp_servers = get(settings, "mcpServers", Dict())

    if haskey(mcp_servers, "julia-repl")
        server_config = mcp_servers["julia-repl"]
        if haskey(server_config, "url") && server_config["url"] == "http://localhost:3000"
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
    settings = read_gemini_settings()

    if !haskey(settings, "mcpServers")
        settings["mcpServers"] = Dict()
    end

    if transport_type == "http"
        settings["mcpServers"]["julia-repl"] = Dict(
            "url" => "http://localhost:3000"
        )
    elseif transport_type == "script"
        settings["mcpServers"]["julia-repl"] = Dict(
            "command" => "$(pkgdir(MCPRepl))/mcp-julia-adapter"
        )
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

function setup()
    claude_status = check_claude_status()
    gemini_status = check_gemini_status()

    # Show current status
    println("🔧 MCPRepl Setup")
    println()

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

    # Claude options
    if claude_status != :claude_not_found
        println("   Claude Code:")
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            println("     [1] Remove Claude MCP configuration")
            println("     [2] Add/Replace Claude with HTTP transport")
            println("     [3] Add/Replace Claude with script transport")
        else
            println("     [1] Add Claude HTTP transport")
            println("     [2] Add Claude script transport")
        end
    end

    # Gemini options
    if gemini_status != :gemini_not_found
        println("   Gemini CLI:")
        if gemini_status in [:configured_http, :configured_script, :configured_unknown]
            println("     [4] Remove Gemini MCP configuration")
            println("     [5] Add/Replace Gemini with HTTP transport")
            println("     [6] Add/Replace Gemini with script transport")
        else
            println("     [4] Add Gemini HTTP transport")
            println("     [5] Add Gemini script transport")
        end
    end

    println()
    print("   Enter choice: ")

    choice = readline()

    # Handle choice
    if choice == "1"
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Removing Claude MCP configuration...")
            try
                run(`claude mcp remove julia-repl`)
                println("   ✅ Successfully removed Claude MCP configuration")
            catch e
                println("   ❌ Failed to remove Claude MCP configuration: $e")
            end
        elseif claude_status != :claude_not_found
            println("\n   Adding Claude HTTP transport...")
            try
                run(`claude mcp add julia-repl http://localhost:3000 --transport http`)
                println("   ✅ Successfully configured Claude HTTP transport")
            catch e
                println("   ❌ Failed to configure Claude HTTP transport: $e")
            end
        end
    elseif choice == "2"
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Adding/Replacing Claude with HTTP transport...")
            try
                run(`claude mcp add julia-repl http://localhost:3000 --transport http`)
                println("   ✅ Successfully configured Claude HTTP transport")
            catch e
                println("   ❌ Failed to configure Claude HTTP transport: $e")
            end
        elseif claude_status != :claude_not_found
            println("\n   Adding Claude script transport...")
            try
                run(`claude mcp add julia-repl $(pkgdir(MCPRepl))/mcp-julia-adapter`)
                println("   ✅ Successfully configured Claude script transport")
            catch e
                println("   ❌ Failed to configure Claude script transport: $e")
            end
        end
    elseif choice == "3"
        if claude_status in [:configured_http, :configured_script, :configured_unknown]
            println("\n   Adding/Replacing Claude with script transport...")
            try
                run(`claude mcp add julia-repl $(pkgdir(MCPRepl))/mcp-julia-adapter`)
                println("   ✅ Successfully configured Claude script transport")
            catch e
                println("   ❌ Failed to configure Claude script transport: $e")
            end
        end
    elseif choice == "4"
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
    elseif choice == "5"
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
    elseif choice == "6"
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
