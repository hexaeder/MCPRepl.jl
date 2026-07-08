using JSON

# Run `cmd`, capturing stdout, but never block longer than `timeout` seconds.
# Belt-and-suspenders backstop for the Claude CLI health-check (see below); on
# timeout we kill the process and return "" (treated as "not configured" —
# purely cosmetic, it only drives the startup splash).
function _read_cmd_timeout(cmd::Cmd; timeout::Real = 5.0)
    proc = open(pipeline(cmd; stderr = devnull))
    timer = Timer(_ -> (process_running(proc) && kill(proc)), timeout)
    try
        return read(proc, String)
    catch
        return ""
    finally
        close(timer)
    end
end

function check_claude_status()
    # Check if claude command exists
    try
        run(pipeline(`which claude`, devnull))
    catch
        return :claude_not_found
    end

    # Check if the julia-repl MCP server is configured.
    #
    # We use `claude mcp get julia-repl`, NOT `claude mcp list`: newer Claude CLIs
    # health-check servers, and `list` health-checks *every* configured server —
    # so one unreachable/slow server elsewhere stalls REPL startup for ~30s.
    # `get julia-repl` only checks this one server (local + already running here),
    # so it returns promptly. The timeout above is a backstop.
    try
        output = _read_cmd_timeout(`claude mcp get julia-repl`; timeout = 5.0)
        # Detect configuration (the adapter path appears only when configured)
        if contains(output, "mcp-julia-adapter")
            return :configured_script
        elseif contains(output, "Scope:") || contains(output, "Status:")
            return :configured_unknown
        else
            # "No MCP server named ..." / empty (timeout) → not configured
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
        content = JSON.json(settings; pretty = 4)
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
        if haskey(server_config, "command")
            return :configured_script
        else
            return :configured_unknown
        end
    else
        return :not_configured
    end
end

function add_gemini_mcp_server()
    settings = read_gemini_settings()

    if !haskey(settings, "mcpServers")
        settings["mcpServers"] = Dict()
    end

    settings["mcpServers"]["julia-repl"] = Dict(
        "command" => "$(pkgdir(MCPRepl))/mcp-julia-adapter"
    )

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

# --- Claude configuration actions -------------------------------------------
# `scope` is one of "local" (this project only) or "user" (all projects).
function claude_add_cmd(scope::String)
    scope_flag = scope == "local" ? String[] : ["-s", scope]
    return `claude mcp add $scope_flag julia-repl $(pkgdir(MCPRepl))/mcp-julia-adapter`
end

function configure_claude(scope::String)
    scopelabel = scope == "user" ? "user — all projects" : "local — this project"
    label = "adapter ($scopelabel)"
    println("\n   Configuring Claude with $label ...")
    # Best-effort remove of any existing entry in this scope so re-runs truly replace.
    try
        run(pipeline(`claude mcp remove julia-repl -s $scope`; stdout = devnull, stderr = devnull))
    catch
    end
    try
        run(claude_add_cmd(scope))
        println("   ✅ Successfully configured Claude $label")
    catch e
        println("   ❌ Failed to configure Claude $label: $e")
    end
end

function remove_claude()
    println("\n   Removing Claude MCP configuration...")
    # Try both scopes so we clear it wherever it lives.
    removed = false
    for scope in ("local", "user")
        try
            run(pipeline(`claude mcp remove julia-repl -s $scope`; stdout = devnull, stderr = devnull))
            removed = true
        catch
        end
    end
    println(removed ? "   ✅ Successfully removed Claude MCP configuration" :
                      "   ❌ No Claude MCP configuration found to remove")
end

# --- Gemini configuration actions (settings.json is inherently user-wide) ----
function configure_gemini()
    println("\n   Configuring Gemini with the adapter ...")
    if add_gemini_mcp_server()
        println("   ✅ Successfully configured Gemini")
    else
        println("   ❌ Failed to configure Gemini")
    end
end

function remove_gemini()
    println("\n   Removing Gemini MCP configuration...")
    if remove_gemini_mcp_server()
        println("   ✅ Successfully removed Gemini MCP configuration")
    else
        println("   ❌ Failed to remove Gemini MCP configuration")
    end
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
    elseif claude_status in (:configured_script, :configured_unknown)
        println("📊 Claude status: ✅ Julia REPL adapter configured")
    else
        println("📊 Claude status: ❌ Julia REPL adapter not configured")
    end

    # Gemini status
    if gemini_status == :gemini_not_found
        println("📊 Gemini status: ❌ Gemini CLI not found in PATH")
    elseif gemini_status in (:configured_script, :configured_unknown)
        println("📊 Gemini status: ✅ Julia REPL adapter configured")
    else
        println("📊 Gemini status: ❌ Julia REPL adapter not configured")
    end
    println()

    # Show options. Build a numbered action list dynamically so entries can be
    # added/removed (e.g. per scope, or depending on current config) without
    # juggling hardcoded choice numbers.
    println("Available actions:")
    actions = Function[]
    offer(label, action) = (push!(actions, action); println("     [$(length(actions))] $label"))

    if claude_status != :claude_not_found
        configured = claude_status in (:configured_script, :configured_unknown)
        verb = configured ? "Add/Replace" : "Add"
        println("   Claude Code:")
        configured && offer("Remove Claude MCP configuration", remove_claude)
        offer("$verb adapter (local — this project)", () -> configure_claude("local"))
        offer("$verb adapter (user — ALL projects)", () -> configure_claude("user"))
    end

    if gemini_status != :gemini_not_found
        configured = gemini_status in (:configured_script, :configured_unknown)
        verb = configured ? "Add/Replace" : "Add"
        println("   Gemini CLI (settings.json is user-wide):")
        configured && offer("Remove Gemini MCP configuration", remove_gemini)
        offer("$verb adapter", configure_gemini)
    end

    println()
    print("   Enter choice: ")

    choice = tryparse(Int, strip(readline()))
    if choice === nothing || choice < 1 || choice > length(actions)
        println("\n   Invalid choice. Please run MCPRepl.setup() again.")
        return
    end
    actions[choice]()

    println()
    println("   💡 The adapter multiplexes across several REPLs and lets agents")
    println("      spawn their own private REPLs when none is running.")
    println("   💡 'user' scope makes the adapter available in all your projects")
end