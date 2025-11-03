module MCPRepl

using REPL
using JSON
using InteractiveUtils
using Profile
using HTTP
using Random
using SHA
using Dates

export @mcp_tool

# ============================================================================
# Tool Definition Macros
# ============================================================================

"""
    @mcp_tool id description params handler

Define an MCP tool with symbol-based identification.

# Arguments
- `id`: Symbol literal (e.g., :exec_repl) - becomes both internal ID and string name
- `description`: String describing the tool
- `params`: Parameters schema Dict
- `handler`: Function taking (args) or (args, stream_channel)

# Examples
```julia
tool = @mcp_tool :exec_repl "Execute Julia code" Dict(
    "type" => "object",
    "properties" => Dict("expression" => Dict("type" => "string")),
    "required" => ["expression"]
) (args, stream_channel=nothing) -> begin
    execute_repllike(get(args, "expression", ""); stream_channel=stream_channel)
end
```
"""
macro mcp_tool(id, description, params, handler)
    if !(id isa QuoteNode || (id isa Expr && id.head == :quote))
        error("@mcp_tool requires a symbol literal for id, got: $id")
    end

    # Extract the symbol from QuoteNode
    id_sym = id isa QuoteNode ? id.value : id.args[1]
    name_str = string(id_sym)

    return esc(
        quote
            $MCPRepl.MCPTool(
                $(QuoteNode(id_sym)),    # :exec_repl
                $name_str,                # "exec_repl"
                $description,
                $params,
                $handler,
            )
        end,
    )
end

include("security.jl")
include("security_wizard.jl")
include("Supervisor.jl")
include("MCPServer.jl")
include("setup.jl")
include("vscode.jl")
include("lsp.jl")
include("Generate.jl")

# ============================================================================
# VS Code Response Storage for Bidirectional Communication
# ============================================================================

# Global dictionary to store VS Code command responses
# Key: request_id (String), Value: (result, error, timestamp)
const VSCODE_RESPONSES = Dict{String,Tuple{Any,Union{Nothing,String},Float64}}()

# Lock for thread-safe access to response dictionary
const VSCODE_RESPONSE_LOCK = ReentrantLock()

# Global dictionary to store single-use nonces for VS Code callbacks
# Key: request_id (String), Value: (nonce, timestamp)
const VSCODE_NONCES = Dict{String,Tuple{String,Float64}}()

# Lock for thread-safe access to nonces dictionary
const VSCODE_NONCE_LOCK = ReentrantLock()

# Global reference to supervisor registry (if supervisor mode is enabled)
const SUPERVISOR_REGISTRY = Ref{Union{Supervisor.AgentRegistry,Nothing}}(nothing)

"""
    store_vscode_response(request_id::String, result, error::Union{Nothing,String})

Store a response from VS Code for later retrieval.
Thread-safe storage using VSCODE_RESPONSE_LOCK.
"""
function store_vscode_response(request_id::String, result, error::Union{Nothing,String})
    lock(VSCODE_RESPONSE_LOCK) do
        VSCODE_RESPONSES[request_id] = (result, error, time())
    end
end

"""
    retrieve_vscode_response(request_id::String; timeout::Float64=5.0, poll_interval::Float64=0.1)

Retrieve a stored VS Code response, waiting up to `timeout` seconds.
Returns (result, error) tuple or throws TimeoutError.
Automatically cleans up the stored response after retrieval.
"""
function retrieve_vscode_response(
    request_id::String;
    timeout::Float64 = 5.0,
    poll_interval::Float64 = 0.1,
)
    start_time = time()

    while (time() - start_time) < timeout
        response = lock(VSCODE_RESPONSE_LOCK) do
            get(VSCODE_RESPONSES, request_id, nothing)
        end

        if response !== nothing
            # Clean up the stored response
            lock(VSCODE_RESPONSE_LOCK) do
                delete!(VSCODE_RESPONSES, request_id)
            end
            return (response[1], response[2])  # (result, error)
        end

        sleep(poll_interval)
    end

    error("Timeout waiting for VS Code response (request_id: $request_id)")
end

"""
    cleanup_old_vscode_responses(max_age::Float64=60.0)

Remove responses older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_vscode_responses(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_RESPONSE_LOCK) do
        for (request_id, (_, _, timestamp)) in collect(VSCODE_RESPONSES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_RESPONSES, request_id)
            end
        end
    end
end

# ============================================================================
# Nonce Management for VS Code Authentication
# ============================================================================

"""
    generate_nonce()

Generate a cryptographically secure random nonce for single-use authentication.
Returns a 32-character hex string.
"""
function generate_nonce()
    return bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
end

"""
    store_nonce(request_id::String, nonce::String)

Store a nonce for a specific request ID. Thread-safe.
"""
function store_nonce(request_id::String, nonce::String)
    lock(VSCODE_NONCE_LOCK) do
        VSCODE_NONCES[request_id] = (nonce, time())
    end
end

"""
    validate_and_consume_nonce(request_id::String, nonce::String)::Bool

Validate that a nonce matches the stored nonce for a request ID, then consume it (delete it).
Returns true if valid, false otherwise. Thread-safe.
"""
function validate_and_consume_nonce(request_id::String, nonce::String)::Bool
    lock(VSCODE_NONCE_LOCK) do
        stored = get(VSCODE_NONCES, request_id, nothing)
        if stored === nothing
            return false
        end

        stored_nonce, _ = stored
        # Delete immediately to prevent reuse
        delete!(VSCODE_NONCES, request_id)

        return stored_nonce == nonce
    end
end

"""
    cleanup_old_nonces(max_age::Float64=60.0)

Remove nonces older than `max_age` seconds to prevent memory leaks.
Should be called periodically.
"""
function cleanup_old_nonces(max_age::Float64 = 60.0)
    current_time = time()
    lock(VSCODE_NONCE_LOCK) do
        for (request_id, (_, timestamp)) in collect(VSCODE_NONCES)
            if (current_time - timestamp) > max_age
                delete!(VSCODE_NONCES, request_id)
            end
        end
    end
end

# ============================================================================
# VS Code URI Helpers
# ============================================================================

# Helper function to trigger VS Code commands via URI
function trigger_vscode_uri(uri::String)
    if Sys.isapple()
        run(`open $uri`)
    elseif Sys.islinux()
        run(`xdg-open $uri`)
    elseif Sys.iswindows()
        run(`cmd /c start $uri`)
    else
        error("Unsupported operating system")
    end
end

# Helper function to build VS Code command URI
function build_vscode_uri(
    command::String;
    args::Union{Nothing,String} = nothing,
    request_id::Union{Nothing,String} = nothing,
    mcp_port::Int = 3000,
    nonce::Union{Nothing,String} = nothing,
    publisher::String = "MCPRepl",
    name::String = "vscode-remote-control",
)
    uri = "vscode://$(publisher).$(name)?cmd=$(command)"
    if args !== nothing
        uri *= "&args=$(args)"
    end
    if request_id !== nothing
        uri *= "&request_id=$(request_id)"
    end
    if mcp_port != 3000
        uri *= "&mcp_port=$(mcp_port)"
    end
    if nonce !== nothing
        uri *= "&nonce=$(HTTP.URIs.escapeuri(nonce))"
    end
    return uri
end

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
# Resolve ambiguities with Base.Multimedia
Base.displayable(::IOBufferDisplay, ::AbstractString) = true
Base.displayable(::IOBufferDisplay, ::MIME) = true
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime::AbstractString, x) = show(d.io, MIME(mime), x)
Base.display(d::IOBufferDisplay, mime::MIME, x) = show(d.io, mime, x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

"""
    remove_println_calls(expr, toplevel=true)

Strip println, print, printstyled, @show, and logging macros from an AST expression.
When quiet mode is on, agents shouldn't use these to communicate since
the user already sees code execution in their REPL.

Logging macros (@error, @debug, @info, @warn) are only removed at the top level,
not inside function definitions or other nested code.
"""
function remove_println_calls(expr, toplevel::Bool = true)
    if expr isa Expr
        # Check if this is a print-related call
        if expr.head == :call
            func = expr.args[1]
            # List of functions to remove (always, regardless of level)
            print_funcs = [:println, :print, :printstyled]
            # Match direct calls (println, print, printstyled)
            if func in print_funcs
                return nothing
            end
            # Match qualified calls (Base.println, Main.print, etc.)
            if (
                func isa Expr &&
                func.head == :. &&
                length(func.args) >= 2 &&
                func.args[end] isa QuoteNode &&
                func.args[end].value in print_funcs
            )
                return nothing
            end
        elseif expr.head == :macrocall
            macro_name = expr.args[1]
            # Remove @show always
            if macro_name == Symbol("@show")
                return nothing
            end
            # Remove logging macros ONLY at top level
            if toplevel
                logging_macros =
                    [Symbol("@error"), Symbol("@debug"), Symbol("@info"), Symbol("@warn")]
                if macro_name in logging_macros
                    return nothing
                end
                # Also handle qualified logging macros
                if (
                    macro_name isa Expr &&
                    macro_name.head == :. &&
                    length(macro_name.args) >= 2 &&
                    macro_name.args[end] isa QuoteNode &&
                    macro_name.args[end].value in [:error, :debug, :info, :warn]
                )
                    return nothing
                end
            end
        end

        # Determine if we're entering a nested scope (not top level anymore)
        entering_nested = expr.head in [:function, :macro, :let, :do, :try, :->]

        # Recursively process all arguments, filtering out nothings
        new_args = []
        for arg in expr.args
            cleaned = remove_println_calls(arg, toplevel && !entering_nested)
            if cleaned !== nothing
                push!(new_args, cleaned)
            end
        end
        # If we have a block and removed some statements, rebuild it
        if expr.head == :block && length(new_args) != length(expr.args)
            return Expr(expr.head, new_args...)
        else
            return Expr(expr.head, new_args...)
        end
    end
    return expr
end

function execute_repllike(
    str;
    silent::Bool = false,
    quiet::Bool = true,
    description::Union{String,Nothing} = nothing,
)
    # Check for Pkg.activate usage
    if contains(str, "activate(") && !contains(str, r"#.*overwrite no-activate-rule")
        return """
            ERROR: Using Pkg.activate to change environments is not allowed.
            You should assume you are in the correct environment for your tasks.
            You may use Pkg.status() to see the current environment and available packages.
            If you need to use a third-party 'activate' function, add '# overwrite no-activate-rule' at the end of your command.
        """
    end

    repl = Base.active_repl

    # Auto-append semicolon in quiet mode to suppress output
    if quiet && !REPL.ends_with_semicolon(str)
        str = str * ";"
    end

    expr = Base.parse_input_line(str)

    # In quiet mode, strip println statements from the AST
    # User already sees code execution in their REPL - println is redundant
    if quiet
        expr = remove_println_calls(expr)
    end

    backend = repl.backendref

    REPL.prepare_next(repl)

    # Only print the agent prompt if not silent
    if !silent
        printstyled("\nagent> ", color = :red, bold = :true)
        if description !== nothing
            println(description)
        else
            # Transform println calls to comments for display
            display_str = replace(str, r"println\s*\(\s*\"([^\"]*)\"\s*\)" => s"# \1")
            display_str = replace(display_str, r"@info\s+\"([^\"]*?)\"" => s"# \1")
            display_str = replace(display_str, r"@warn\s+\"([^\"]*?)\"" => s"# WARNING: \1")
            display_str = replace(display_str, r"@error\s+\"([^\"]*?)\"" => s"# ERROR: \1")
            # Split on semicolons for multi-line display
            display_str = replace(display_str, r";\s*" => "\n")
            # If multiline, start on new line for proper indentation
            if contains(display_str, '\n')
                println()  # Start on new line
                print(display_str, "\n")
            else
                print(display_str, "\n")
            end
        end
    end

    # Use pipes for capturing output (simpler approach)
    orig_stdout = stdout
    orig_stderr = stderr

    # redirect_stdout/stderr return (reader, writer) pipe pair
    stdout_read, stdout_write = redirect_stdout()
    stderr_read, stderr_write = redirect_stderr()

    # Capture output in background task
    stdout_content = String[]
    stderr_content = String[]

    stdout_task = @async begin
        try
            while !eof(stdout_read)
                line = readline(stdout_read; keep = true)
                push!(stdout_content, line)
                # Show real-time output unless silent mode
                if !silent
                    write(orig_stdout, line)
                    flush(orig_stdout)
                end
            end
        catch e
            if !isa(e, EOFError)
                @debug "stdout read error" exception=e
            end
        end
    end

    stderr_task = @async begin
        try
            while !eof(stderr_read)
                line = readline(stderr_read; keep = true)
                push!(stderr_content, line)
                # Show real-time output unless silent mode
                if !silent
                    write(orig_stderr, line)
                    flush(orig_stderr)
                end
            end
        catch e
            if !isa(e, EOFError)
                @debug "stderr read error" exception=e
            end
        end
    end

    # Evaluate the expression
    response = try
        result_pair = REPL.eval_on_backend(expr, backend)
        result_pair.first  # Extract result from Pair{Any, Bool}
    catch e
        e
    finally
        # Restore streams and clean up pipes
        redirect_stdout(orig_stdout)
        redirect_stderr(orig_stderr)

        # Close write ends to signal EOF
        close(stdout_write)
        close(stderr_write)

        # Wait for readers to finish
        wait(stdout_task)
        wait(stderr_task)

        # Close read ends
        close(stdout_read)
        close(stderr_read)
    end

    # Get captured output
    captured_content = join(stdout_content) * join(stderr_content)

    # Note: Output was already displayed in real-time by the async tasks
    # No need to print captured_content again unless silent mode

    # Format the result for display
    result_str = if !REPL.ends_with_semicolon(str)
        io_buf = IOBuffer()
        show(io_buf, MIME("text/plain"), response)
        String(take!(io_buf))
    else
        ""
    end

    # Refresh REPL if not silent
    if !silent
        if !isempty(result_str)
            println(result_str)
        end
        REPL.prepare_next(repl)
        REPL.LineEdit.refresh_line(repl.mistate)
    end

    # In quiet mode, don't return captured stdout/stderr (println output)
    # User already saw it in their REPL, no need to send it back to agent
    if quiet
        return result_str  # Only return the result value (which is "" in quiet mode)
    else
        return captured_content * result_str
    end
end

SERVER = Ref{Union{Nothing,MCPServer}}(nothing)

function repl_status_report()
    if !isdefined(Main, :Pkg)
        error("Expect Main.Pkg to be defined.")
    end
    Pkg = Main.Pkg

    try
        # Basic environment info
        println("🔍 Julia Environment Investigation")
        println("="^50)
        println()

        # Current directory
        println("📁 Current Directory:")
        println("   $(pwd())")
        println()

        # Active project
        active_proj = Base.active_project()
        println("📦 Active Project:")
        if active_proj !== nothing
            println("   Path: $active_proj")
            try
                project_data = Pkg.TOML.parsefile(active_proj)
                if haskey(project_data, "name")
                    println("   Name: $(project_data["name"])")
                else
                    println("   Name: $(basename(dirname(active_proj)))")
                end
                if haskey(project_data, "version")
                    println("   Version: $(project_data["version"])")
                end
            catch e
                println("   Error reading project info: $e")
            end
        else
            println("   No active project")
        end
        println()

        # Package status
        println("📚 Package Environment:")
        try
            # Get package status (suppress output)
            pkg_status = redirect_stdout(devnull) do
                Pkg.status(; mode = Pkg.PKGMODE_MANIFEST)
            end

            # Parse dependencies for development packages
            deps = Pkg.dependencies()
            dev_packages = Dict{String,String}()

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep && pkg_info.is_tracking_path
                    dev_packages[pkg_info.name] = pkg_info.source
                end
            end

            # Add current environment package if it's a development package
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_dir = dirname(active_proj)
                        # This is a development package since we're in its source
                        dev_packages[pkg_name] = pkg_dir
                    end
                catch
                    # Not a package, that's fine
                end
            end

            # Check if current environment is itself a package and collect its info
            current_env_package = nothing
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_version = get(project_data, "version", "dev")
                        pkg_uuid = project_data["uuid"]
                        current_env_package = (
                            name = pkg_name,
                            version = pkg_version,
                            uuid = pkg_uuid,
                            path = dirname(active_proj),
                        )
                    end
                catch
                    # Not a package environment, that's fine
                end
            end

            # Separate development packages from regular packages
            dev_deps = []
            regular_deps = []

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep
                    if haskey(dev_packages, pkg_info.name)
                        push!(dev_deps, pkg_info)
                    else
                        push!(regular_deps, pkg_info)
                    end
                end
            end

            # List development packages first (with current environment package at the top if applicable)
            has_dev_packages = !isempty(dev_deps) || current_env_package !== nothing
            if has_dev_packages
                println("   🔧 Development packages (tracked by Revise):")

                # Show current environment package first if it exists
                if current_env_package !== nothing
                    println(
                        "      $(current_env_package.name) v$(current_env_package.version) [CURRENT ENV] => $(current_env_package.path)",
                    )
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(current_env_package.name)
                        if pkg_dir !== nothing && pkg_dir != current_env_package.path
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end

                # Then show other development packages
                for pkg_info in dev_deps
                    # Skip if this is the same as the current environment package
                    if current_env_package !== nothing &&
                       pkg_info.name == current_env_package.name
                        continue
                    end
                    println(
                        "      $(pkg_info.name) v$(pkg_info.version) => $(dev_packages[pkg_info.name])",
                    )
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(pkg_info.name)
                        if pkg_dir !== nothing && pkg_dir != dev_packages[pkg_info.name]
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end
                println()
            end

            # List regular packages second
            if !isempty(regular_deps)
                println("   📦 Other packages in environment:")
                for pkg_info in regular_deps
                    println("      $(pkg_info.name) v$(pkg_info.version)")
                end
            end

            # Handle empty environment
            if isempty(deps) && current_env_package === nothing
                println("   No packages in environment")
            end

        catch e
            println("   Error getting package status: $e")
        end

        println()
        println("🔄 Revise.jl Status:")
        try
            if isdefined(Main, :Revise)
                println("   ✅ Revise.jl is loaded and active")
                println("   📝 Development packages will auto-reload on changes")
            else
                println("   ⚠️  Revise.jl is not loaded")
            end
        catch
            println("   ❓ Could not determine Revise.jl status")
        end

        return nothing

    catch e
        println("Error generating environment report: $e")
        return nothing
    end
end

# ============================================================================
# Tool Configuration Management
# ============================================================================

"""
    load_tools_config(config_path::String = ".mcprepl/tools.json")

Load the tools configuration from .mcprepl/tools.json.
Returns a Set of enabled tool names (as Symbols).

The configuration supports:
- Tool sets that can be enabled/disabled as groups
- Individual tool overrides that take precedence over tool set settings

If the config file doesn't exist, returns `nothing` to indicate all tools should be enabled.
"""
function load_tools_config(config_path::String = ".mcprepl/tools.json")
    full_path = joinpath(pwd(), config_path)

    # If config doesn't exist, enable all tools (backward compatibility)
    if !isfile(full_path)
        return nothing
    end

    try
        config = JSON.parsefile(full_path; dicttype = Dict{String,Any})
        enabled_tools = Set{Symbol}()

        # First, process tool sets
        tool_sets = get(config, "tool_sets", Dict())
        for (set_name, set_config) in tool_sets
            if get(set_config, "enabled", false)
                tools = get(set_config, "tools", String[])
                for tool_name in tools
                    push!(enabled_tools, Symbol(tool_name))
                end
            end
        end

        # Then apply individual overrides
        individual_overrides = get(config, "individual_overrides", Dict())
        for (tool_name, enabled) in individual_overrides
            # Skip comment entries
            if startswith(tool_name, "_")
                continue
            end

            tool_sym = Symbol(tool_name)
            if enabled
                push!(enabled_tools, tool_sym)
            else
                delete!(enabled_tools, tool_sym)
            end
        end

        return enabled_tools
    catch e
        @warn "Error loading tools configuration from $full_path: $e. Enabling all tools."
        return nothing
    end
end

"""
    filter_tools_by_config(all_tools::Vector{MCPTool}, enabled_tools::Union{Set{Symbol},Nothing})

Filter a vector of MCPTool objects based on the enabled tools set.
If enabled_tools is `nothing`, returns all tools (backward compatibility).
"""
function filter_tools_by_config(
    all_tools::Vector{MCPTool},
    enabled_tools::Union{Set{Symbol},Nothing},
)
    if enabled_tools === nothing
        return all_tools
    end

    return filter(tool -> tool.id in enabled_tools, all_tools)
end

"""
    start_agent_heartbeat(agent_name::String, agents_config::String, verbose::Bool)

Start a background task that sends periodic heartbeats to the supervisor.

This function spawns a separate thread that:
1. Reads supervisor configuration from agents.json
2. Sends HTTP POST heartbeats every second
3. Silently ignores failures (supervisor may not be running yet)

The heartbeat task runs indefinitely until the Julia process exits.
"""
function start_agent_heartbeat(agent_name::String, agents_config::String, verbose::Bool)
    if verbose
        printstyled("💓 Agent Heartbeat: ", color = :cyan, bold = true)
        printstyled("Enabled for '$agent_name'\n", color = :green, bold = true)
    end

    # Spawn heartbeat task on a separate thread
    Threads.@spawn begin
        # Read supervisor configuration
        config_path = agents_config  # Already includes .mcprepl/ prefix
        supervisor_port = nothing

        if isfile(config_path)
            try
                config = JSON.parsefile(config_path)
                supervisor_port = get(get(config, "supervisor", Dict()), "port", nothing)
                if supervisor_port === nothing
                    @warn "Supervisor port not found in $config_path, heartbeat disabled"
                    return
                end
            catch e
                @warn "Could not read supervisor config from $config_path" exception=e
                return
            end
        else
            @warn "Agents config file not found at $config_path, heartbeat disabled"
            return
        end

        supervisor_url = "http://localhost:$supervisor_port/"

        if verbose
            printstyled("   • Sending to: $supervisor_url\n", color = :green)
            println()
        end

        # Heartbeat loop
        while true
            try
                heartbeat = Dict(
                    "jsonrpc" => "2.0",
                    "method" => "supervisor/heartbeat",
                    "id" => 1,
                    "params" => Dict(
                        "agent_name" => agent_name,
                        "pid" => getpid(),
                        "status" => "healthy",
                        "timestamp" => string(Dates.now()),
                    ),
                )

                HTTP.post(
                    supervisor_url,
                    ["Content-Type" => "application/json"],
                    JSON.json(heartbeat);
                    readtimeout = 2,
                    connect_timeout = 1,
                )
            catch e
                # Silently ignore heartbeat failures (supervisor may not be running yet)
            end

            sleep(1)  # Send heartbeat every second
        end
    end
end

function start!(;
    port::Union{Int,Nothing} = nothing,
    verbose::Bool = true,
    security_mode::Union{Symbol,Nothing} = nothing,
    supervisor::Bool = false,
    agents_config::String = ".mcprepl/agents.json",
    agent_name::String = "",
    workspace_dir::String = pwd(),
)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    # Load or prompt for security configuration
    # Pass agent_name and supervisor flag so it can load from agents.json if needed
    # Use workspace_dir (project root) not pwd() (which may be agent dir)
    security_config = load_security_config(workspace_dir, agent_name, supervisor)

    if security_config === nothing
        printstyled("\n⚠️  NO SECURITY CONFIGURATION FOUND\n", color = :red, bold = true)
        println()
        println("MCPRepl requires security configuration before starting.")
        println("Run MCPRepl.setup() to configure API keys and security settings.")
        println()
        error("Security configuration required. Run MCPRepl.setup() first.")
    end

    # Determine port: priority is function arg > supervisor config > security config
    actual_port = if port !== nothing
        port
    elseif supervisor
        # In supervisor mode, read port from agents config
        if isfile(agents_config)
            try
                config = JSON.parsefile(agents_config)
                supervisor_config = get(config, "supervisor", Dict())
                if !haskey(supervisor_config, "port")
                    error("Supervisor mode requires 'port' field in $agents_config under 'supervisor' section")
                end
                supervisor_config["port"]
            catch e
                error("Failed to read supervisor port from $agents_config: $e")
            end
        else
            error("Supervisor mode requires $agents_config file with supervisor.port configuration")
        end
    else
        security_config.port
    end

    # Override security mode if specified
    if security_mode !== nothing
        if !(security_mode in [:strict, :relaxed, :lax])
            error("Invalid security_mode. Must be :strict, :relaxed, or :lax")
        end
        security_config = SecurityConfig(
            security_mode,
            security_config.api_keys,
            security_config.allowed_ips,
            security_config.port,
            security_config.created_at,
        )
    end

    # Show security status if verbose
    if verbose
        printstyled("\n🔒 Security Mode: ", color = :cyan, bold = true)
        printstyled("$(security_config.mode)\n", color = :green, bold = true)
        if security_config.mode == :strict
            println("   • API key required + IP allowlist enforced")
        elseif security_config.mode == :relaxed
            println("   • API key required + any IP allowed")
        elseif security_config.mode == :lax
            println("   • Localhost only + no API key required")
        end
        printstyled("📡 Server Port: ", color = :cyan, bold = true)
        printstyled("$actual_port\n", color = :green, bold = true)
        println()
    end

    # Initialize supervisor if requested
    if supervisor
        if verbose
            printstyled("👁️  Supervisor Mode: ", color = :cyan, bold = true)
            printstyled("Enabled\n", color = :green, bold = true)
        end

        # Load agents configuration
        registry = Supervisor.load_agents_config(agents_config)

        if registry === nothing
            @warn "Failed to load agents configuration from $agents_config. Supervisor mode disabled."
        else
            # Store registry globally
            SUPERVISOR_REGISTRY[] = registry

            # Start supervisor monitor loop
            Supervisor.start_supervisor(registry)

            if verbose
                agent_count = length(registry.agents)
                printstyled("   • Managing $agent_count agent(s)\n", color = :green)

                # Start auto-start agents
                auto_start_count = 0
                for (name, agent) in Supervisor.get_all_agents(registry)
                    if agent.auto_start
                        if Supervisor.start_agent(agent)
                            auto_start_count += 1
                        end
                    end
                end

                if auto_start_count > 0
                    printstyled(
                        "   • Auto-started $auto_start_count agent(s)\n",
                        color = :green,
                    )
                end
                println()
            end
        end
    end

    # Start heartbeat task if running as an agent
    if !isempty(agent_name)
        start_agent_heartbeat(agent_name, agents_config, verbose)
    end

    ping_tool = @mcp_tool(
        :ping,
        "Check if the MCP server is responsive and return Revise.jl status.",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        args -> begin
            status = "✓ MCP Server is healthy and responsive\n"

            # Check Revise status
            if isdefined(Main, :Revise)
                revise_errors = Main.Revise.errors()
                if revise_errors === nothing
                    status *= "Revise: active (no errors)"
                else
                    status *= "Revise: active (has errors - call Revise.errors() for details)"
                end
            else
                status *= "Revise: not loaded"
            end

            return status
        end
    )

    usage_instructions_tool =
        @mcp_tool :usage_instructions "Get Julia REPL usage instructions and best practices for AI agents." Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => [],
        ) (
            args -> begin
                try
                    workflow_path = joinpath(
                        dirname(dirname(@__FILE__)),
                        "prompts",
                        "julia_repl_workflow.md",
                    )

                    if !isfile(workflow_path)
                        return "Error: julia_repl_workflow.md not found at $workflow_path"
                    end

                    return read(workflow_path, String)
                catch e
                    return "Error reading usage instructions: $e"
                end
            end
        )

    usage_quiz_tool = @mcp_tool(
        :usage_quiz,
        """Test your understanding of MCPRepl usage patterns with a self-graded quiz.

This tool helps AI agents verify they understand the correct usage patterns for the `ex` tool
and the shared REPL model before working with users.

# Modes

**Default (no arguments):** Returns quiz questions
- 6 questions testing understanding of:
  - Shared REPL model
  - When to use q=false vs q=true (default)
  - Communication channels (TEXT vs code vs println)
  - Token efficiency
  - Real-world scenarios
- Agent should answer questions and output responses to user

**With show_sols=true:** Returns solutions and grading instructions
- Canonical answers for all questions
- Point values and grading rubrics
- Instructions to self-grade and report score to user
- If score < 75, agent must review usage_instructions and retake

# Usage

```julia
# Take the quiz
usage_quiz()
# [Agent answers questions in their response to user]

# Check answers and grade yourself
usage_quiz(show_sols=true)
# [Agent compares answers, calculates score, reports to user]
```

# Purpose

Ensures agents understand:
- NOT to use println for communication (user sees REPL output directly)
- Default to q=true (quiet mode) - only use q=false when you need return values for decisions
- Token efficiency (70-90% savings with correct usage)
- Communication happens in TEXT responses, not code

**Recommended:** New agents should take this quiz before starting work to verify understanding.""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "show_sols" => Dict(
                    "type" => "boolean",
                    "description" => "If true, return solutions and grading instructions. If false/omitted, return quiz questions.",
                    "default" => false,
                ),
            ),
            "required" => [],
        ),
        args -> begin
            try
                show_solutions = get(args, "show_sols", false)

                filename = if show_solutions
                    "usage_quiz_solutions.md"
                else
                    "usage_quiz_questions.md"
                end

                quiz_path = joinpath(dirname(dirname(@__FILE__)), "prompts", filename)

                if !isfile(quiz_path)
                    return "Error: $filename not found at $quiz_path"
                end

                return read(quiz_path, String)
            catch e
                return "Error reading quiz file: $e"
            end
        end
    )

    repl_tool = @mcp_tool(
        :ex,
        """Execute Julia code in a persistent REPL. User sees all code execute in real-time.

Default (q=true): Returns only printed output/errors, suppresses return values (saves 70-90% tokens).
Verbose (q=false): Returns full output including return value - use ONLY when you need the result to make a decision.

Never use `julia` in bash. Call usage_instructions first for workflow guidance.""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "e" => Dict(
                    "type" => "string",
                    "description" => "Julia expression to evaluate (e.g., '2 + 3 * 4' or 'using Pkg; Pkg.status()')",
                ),
                "q" => Dict(
                    "type" => "boolean",
                    "description" => "Quiet mode: suppresses return value to save tokens (default: true). Set to false to see the computed result.",
                ),
                "s" => Dict(
                    "type" => "boolean",
                    "description" => "Silent mode: suppresses 'agent>' prompt and real-time output (default: false)",
                ),
            ),
            "required" => ["e"],
        ),
        (args) -> begin
            try
                silent = get(args, "s", false)
                quiet = get(args, "q", true)
                expr_str = get(args, "e", "")

                # Format long one-liners for readability (if JuliaFormatter available)
                if length(expr_str) > 80 && isdefined(Main, :JuliaFormatter)
                    try
                        formatted = Main.JuliaFormatter.format_text(expr_str)
                        # Only use formatted version if it's actually multiline
                        if count('\n', formatted) > 0
                            expr_str = formatted
                        end
                    catch
                        # If formatting fails, use original
                    end
                end

                execute_repllike(expr_str; silent = silent, quiet = quiet)
            catch e
                println("Error during execute_repllike", e)
                "Apparently there was an **internal** error to the MCP server: $e"
            end
        end
    )

    restart_repl_tool = @mcp_tool(
        :restart_repl,
        "Restart the Julia REPL. Returns immediately, then server restarts (wait 5s, retry every 2s).",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        (args, stream_channel = nothing) -> begin
            try
                # Get the current server port (before restart)
                server_port = SERVER[] !== nothing ? SERVER[].port : nothing

                # Check if running in VS Code by looking for JULIA_VSCODE_INTERNAL variable
                in_vscode =
                    haskey(ENV, "JULIA_VSCODE_INTERNAL") ||
                    haskey(ENV, "VSCODE_PID") ||
                    isdefined(Main, :VSCodeServer)

                port_msg = server_port !== nothing ? " on port $server_port" : ""

                if in_vscode
                    # Execute the restart command using the vscode URI trigger
                    restart_uri = build_vscode_uri(
                        "language-julia.restartREPL";
                        mcp_port = server_port !== nothing ? server_port : 0,
                    )
                    trigger_vscode_uri(restart_uri)

                    return """✓ Julia REPL restart initiated$port_msg.

⏳ The MCP server will be temporarily offline during restart.

**AI Agent Instructions:**
1. Wait 5 seconds before making any requests
2. Then retry every 2 seconds until connection is reestablished
3. Typical restart time: 5-10 seconds (may be longer if packages need recompilation)

The server will automatically restart and be ready when the Julia REPL finishes loading."""
                else
                    # Not in VS Code - use exit() approach
                    # Schedule exit after a brief delay to allow response to be sent
                    @async begin
                        sleep(0.5)
                        exit(0)
                    end

                    return """✓ Julia REPL restart initiated$port_msg.

⏳ The MCP server will be temporarily offline during restart.

**AI Agent Instructions:**
1. Wait 5 seconds before making any requests
2. Then retry every 2 seconds until connection is reestablished
3. Typical restart time: 5-10 seconds (may be longer if packages need recompilation)

**Note:** Running outside VS Code - Julia will exit and needs to be manually restarted.
If Julia is started via the .julia-startup.jl script, it should restart automatically."""
                end
            catch e
                return "Error initiating REPL restart: $e"
            end
        end
    )

    vscode_command_tool = @mcp_tool(
        :execute_vscode_command,
        """Execute any VS Code command via the Remote Control extension.

This tool can trigger any VS Code command that has been allowlisted in the extension configuration.
Useful for automating editor operations like saving files, running tasks, managing windows, etc.

**Prerequisites:**
- VS Code Remote Control extension must be installed (via MCPRepl.setup())
- The command must be in the allowed commands list (see usage_instructions tool for complete list)

**Bidirectional Communication:**
- Set `wait_for_response=true` to wait for and return the command's result
- Useful for commands that return values (e.g., getting debug variable values)
- Default timeout is 5 seconds (configurable via `timeout` parameter)

**Common Command Categories:**
- REPL & Window Control: restartREPL, startREPL, reloadWindow
- File Operations: saveAll, closeAllEditors, openFile
- Navigation: terminal.focus, focusActiveEditorGroup, focusFilesExplorer, quickOpen
- Terminal Operations: sendSequence (execute shell commands without approval dialogs)
- Testing & Debugging: tasks.runTask, debug.start, debug.stop
- Git: git.commit, git.refresh, git.sync
- Search: findInFiles, replaceInFiles
- Window Management: splitEditor, togglePanel, toggleSidebarVisibility
- Extensions: installExtension

**Examples:**
```
execute_vscode_command("workbench.action.files.saveAll")
execute_vscode_command("workbench.action.terminal.focus")
execute_vscode_command("workbench.action.tasks.runTask", ["test"])

# Execute shell commands (RECOMMENDED for julia --project commands):
execute_vscode_command("workbench.action.terminal.sendSequence",
  ["{\"text\": \"julia --project -e 'using Pkg; Pkg.test()'\\r\"}"])

# Get a value back from VS Code:
execute_vscode_command("someCommand", wait_for_response=true, timeout=10.0)
```

For the complete list of available commands and their descriptions, call the usage_instructions tool.""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "command" => Dict(
                    "type" => "string",
                    "description" => "The VS Code command ID to execute (e.g., 'workbench.action.files.saveAll')",
                ),
                "args" => Dict(
                    "type" => "array",
                    "description" => "Optional array of arguments to pass to the command (JSON-encoded)",
                    "items" => Dict("type" => "string"),
                ),
                "wait_for_response" => Dict(
                    "type" => "boolean",
                    "description" => "Wait for command result (default: false). Enable for commands that return values.",
                    "default" => false,
                ),
                "timeout" => Dict(
                    "type" => "number",
                    "description" => "Timeout in seconds when wait_for_response=true (default: 5.0)",
                    "default" => 5.0,
                ),
            ),
            "required" => ["command"],
        ),
        args -> begin
            try
                cmd = get(args, "command", "")
                if isempty(cmd)
                    return "Error: command parameter is required"
                end

                wait_for_response = get(args, "wait_for_response", false)
                timeout = get(args, "timeout", 5.0)

                # Generate unique request ID if waiting for response
                request_id =
                    wait_for_response ? string(rand(UInt128), base = 16) : nothing

                # Build URI with command and optional args
                args_param = nothing
                if haskey(args, "args") && !isempty(args["args"])
                    args_json = JSON.json(args["args"])
                    args_param = HTTP.URIs.escapeuri(args_json)
                end

                uri = build_vscode_uri(cmd; args = args_param, request_id = request_id)
                trigger_vscode_uri(uri)

                # If waiting for response, poll for it
                if wait_for_response
                    try
                        result, error =
                            retrieve_vscode_response(request_id; timeout = timeout)

                        if error !== nothing
                            return "VS Code command '$(cmd)' failed: $error"
                        end

                        # Format result for display
                        if result === nothing
                            return "VS Code command '$(cmd)' executed successfully (no return value)"
                        else
                            # Pretty-print the result
                            result_str = try
                                JSON.json(result)
                            catch
                                string(result)
                            end
                            return "VS Code command '$(cmd)' result:\n$result_str"
                        end
                    catch e
                        return "Error waiting for VS Code response: $e"
                    end
                else
                    return "VS Code command '$(cmd)' executed successfully."
                end
            catch e
                return "Error executing VS Code command: $e. Make sure the VS Code Remote Control extension is installed via MCPRepl.setup()"
            end
        end
    )

    list_vscode_commands_tool = @mcp_tool(
        :list_vscode_commands,
        """List all VS Code commands that are allowed for execution.

Returns the list of commands configured in `.vscode/settings.json` under `vscode-remote-control.allowedCommands`.
Use this to discover which commands are available for the `execute_vscode_command` tool.""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        args -> begin
            try
                settings = read_vscode_settings()
                allowed_commands =
                    get(settings, "vscode-remote-control.allowedCommands", nothing)

                if allowed_commands === nothing || isempty(allowed_commands)
                    return "No VS Code commands configured. Run MCPRepl.setup() to configure the Remote Control extension."
                end

                result = "📋 Allowed VS Code Commands ($(length(allowed_commands)))\n\n"
                for cmd in sort(allowed_commands)
                    result *= "  • $cmd\n"
                end
                return result
            catch e
                return "Error reading VS Code settings: $e"
            end
        end
    )

    tool_help_tool = @mcp_tool(
        :tool_help,
        "Get detailed help and examples for any MCP tool. Use extended=true for additional documentation.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "tool_name" => Dict(
                    "type" => "string",
                    "description" => "Name of the tool to get help for",
                ),
                "extended" => Dict(
                    "type" => "boolean",
                    "description" => "If true, return extended documentation with additional examples (default: false)",
                ),
            ),
            "required" => ["tool_name"],
        ),
        args -> begin
            try
                tool_name = get(args, "tool_name", "")
                if isempty(tool_name)
                    return "Error: tool_name parameter is required"
                end

                extended = get(args, "extended", false)
                tool_id = Symbol(tool_name)

                if SERVER[] === nothing
                    return "Error: MCP server is not running"
                end

                server = SERVER[]
                if !haskey(server.tools, tool_id)
                    return "Error: Tool ':$tool_id' not found. Use list_tools() to see available tools."
                end

                tool = server.tools[tool_id]

                result = "📖 Help for MCP Tool: $tool_name\n"
                result *= "="^70 * "\n\n"
                result *= tool.description * "\n"

                # Try to load extended documentation if requested
                if extended
                    extended_help_path = joinpath(
                        dirname(dirname(@__FILE__)),
                        "extended-help",
                        "$tool_name.md",
                    )

                    if isfile(extended_help_path)
                        result *= "\n\n---\n\n## Extended Documentation\n\n"
                        result *= read(extended_help_path, String)
                    else
                        result *= "\n\n(No extended documentation available for this tool)"
                    end
                end

                return result
            catch e
                return "Error getting tool help: $e"
            end
        end
    )

    investigate_tool = @mcp_tool(
        :investigate_environment,
        "Get current Julia environment info: pwd, active project, packages, dev packages, and Revise status.",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        args -> begin
            try
                execute_repllike("MCPRepl.repl_status_report()"; quiet = false)
            catch e
                "Error investigating environment: $e"
            end
        end
    )

    search_methods_tool = @mcp_tool(
        :search_methods,
        "Search for all methods of a function or methods matching a type signature.",
        MCPRepl.text_parameter(
            "query",
            "Function name or type to search (e.g., 'println', 'String', 'Base.sort')",
        ),
        args -> begin
            try
                query = get(args, "query", "")
                if isempty(query)
                    return "Error: query parameter is required"
                end

                # Try to evaluate the query to get the actual function/type
                code = """
                using InteractiveUtils
                target = $query
                if isa(target, Type)
                    println("Methods with argument type \$target:")
                    println("=" ^ 60)
                    methodswith(target)
                else
                    println("Methods for \$target:")
                    println("=" ^ 60)
                    methods(target)
                end
                """
                execute_repllike(
                    code;
                    description = "[Searching methods for: $query]",
                    quiet = false,
                )
            catch e
                "Error searching methods: \$e"
            end
        end
    )

    macro_expand_tool = @mcp_tool(
        :macro_expand,
        "Expand a macro to see the generated code.",
        MCPRepl.text_parameter(
            "expression",
            "Macro expression to expand (e.g., '@time sleep(1)')",
        ),
        args -> begin
            try
                expr = get(args, "expression", "")
                if isempty(expr)
                    return "Error: expression parameter is required"
                end

                code = """
                using InteractiveUtils
                @macroexpand $expr
                """
                execute_repllike(
                    code;
                    description = "[Expanding macro: $expr]",
                    quiet = false,
                )
            catch e
                "Error expanding macro: \$e"
            end
        end
    )

    type_info_tool = @mcp_tool(
        :type_info,
        "Get type information: hierarchy, fields, parameters, and properties.",
        MCPRepl.text_parameter(
            "type_expr",
            "Type expression to inspect (e.g., 'String', 'Vector{Int}', 'AbstractArray')",
        ),
        args -> begin
            try
                type_expr = get(args, "type_expr", "")
                if isempty(type_expr)
                    return "Error: type_expr parameter is required"
                end

                code = """
                using InteractiveUtils
                T = $type_expr
                println("Type Information for: \$T")
                println("=" ^ 60)
                println()

                # Basic type info
                println("Abstract: ", isabstracttype(T))
                println("Primitive: ", isprimitivetype(T))
                println("Mutable: ", ismutabletype(T))
                println()

                # Type hierarchy
                println("Supertype: ", supertype(T))
                if !isabstracttype(T)
                    println()
                    println("Fields:")
                    if fieldcount(T) > 0
                        for (i, fname) in enumerate(fieldnames(T))
                            ftype = fieldtype(T, i)
                            println("  \$i. \$fname :: \$ftype")
                        end
                    else
                        println("  (no fields)")
                    end
                end

                println()
                println("Direct subtypes:")
                subs = subtypes(T)
                if isempty(subs)
                    println("  (no direct subtypes)")
                else
                    for sub in subs
                        println("  - \$sub")
                    end
                end
                """
                execute_repllike(
                    code;
                    description = "[Getting type info for: $type_expr]",
                    quiet = false,
                )
            catch e
                "Error getting type info: $e"
            end
        end
    )

    profile_tool = @mcp_tool(
        :profile_code,
        "Profile Julia code to identify performance bottlenecks.",
        MCPRepl.text_parameter("code", "Julia code to profile"),
        args -> begin
            try
                code_to_profile = get(args, "code", "")
                if isempty(code_to_profile)
                    return "Error: code parameter is required"
                end

                wrapper = """
                using Profile
                Profile.clear()
                @profile begin
                    $code_to_profile
                end
                Profile.print(format=:flat, sortedby=:count)
                """
                execute_repllike(wrapper; description = "[Profiling code]", quiet = false)
            catch e
                "Error profiling code: \$e"
            end
        end
    )

    list_names_tool = @mcp_tool(
        :list_names,
        "List all exported names in a module or package.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "module_name" => Dict(
                    "type" => "string",
                    "description" => "Module name (e.g., 'Base', 'Core', 'Main')",
                ),
                "all" => Dict(
                    "type" => "boolean",
                    "description" => "Include non-exported names (default: false)",
                ),
            ),
            "required" => ["module_name"],
        ),
        args -> begin
            try
                module_name = get(args, "module_name", "")
                show_all = get(args, "all", false)

                if isempty(module_name)
                    return "Error: module_name parameter is required"
                end

                code = """
                mod = $module_name
                println("Names in \$mod" * (($show_all) ? " (all=true)" : " (exported only)") * ":")
                println("=" ^ 60)
                name_list = names(mod, all=$show_all)
                for name in sort(name_list)
                    println("  ", name)
                end
                println()
                println("Total: ", length(name_list), " names")
                """
                execute_repllike(
                    code;
                    description = "[Listing names in: $module_name]",
                    quiet = false,
                )
            catch e
                "Error listing names: \$e"
            end
        end
    )

    code_lowered_tool = @mcp_tool(
        :code_lowered,
        "Show lowered (desugared) IR for a function.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "function_expr" => Dict(
                    "type" => "string",
                    "description" => "Function to inspect (e.g., 'sin', 'Base.sort')",
                ),
                "types" => Dict(
                    "type" => "string",
                    "description" => "Argument types as tuple (e.g., '(Float64,)', '(Int, Int)')",
                ),
            ),
            "required" => ["function_expr", "types"],
        ),
        args -> begin
            try
                func_expr = get(args, "function_expr", "")
                types_expr = get(args, "types", "")

                if isempty(func_expr) || isempty(types_expr)
                    return "Error: function_expr and types parameters are required"
                end

                code = """
                using InteractiveUtils
                @code_lowered $func_expr($types_expr...)
                """
                execute_repllike(
                    code;
                    description = "[Getting lowered code for: $func_expr with types $types_expr]",
                    quiet = false,
                )
            catch e
                "Error getting lowered code: \$e"
            end
        end
    )

    code_typed_tool = @mcp_tool(
        :code_typed,
        "Show type-inferred code for a function (for debugging type stability).",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "function_expr" => Dict(
                    "type" => "string",
                    "description" => "Function to inspect (e.g., 'sin', 'Base.sort')",
                ),
                "types" => Dict(
                    "type" => "string",
                    "description" => "Argument types as tuple (e.g., '(Float64,)', '(Int, Int)')",
                ),
            ),
            "required" => ["function_expr", "types"],
        ),
        args -> begin
            try
                func_expr = get(args, "function_expr", "")
                types_expr = get(args, "types", "")

                if isempty(func_expr) || isempty(types_expr)
                    return "Error: function_expr and types parameters are required"
                end

                code = """
                using InteractiveUtils
                @code_typed $func_expr($types_expr...)
                """
                execute_repllike(
                    code;
                    description = "[Getting typed code for: $func_expr with types $types_expr]",
                    quiet = false,
                )
            catch e
                "Error getting typed code: \$e"
            end
        end
    )

    # Optional formatting tool (requires JuliaFormatter.jl)
    format_tool = @mcp_tool(
        :format_code,
        "Format Julia code using JuliaFormatter.jl.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "path" => Dict(
                    "type" => "string",
                    "description" => "File or directory path to format",
                ),
                "overwrite" => Dict(
                    "type" => "boolean",
                    "description" => "Overwrite files in place",
                    "default" => true,
                ),
                "verbose" => Dict(
                    "type" => "boolean",
                    "description" => "Show formatting progress",
                    "default" => true,
                ),
            ),
            "required" => ["path"],
        ),
        function (args)
            try
                # Check if JuliaFormatter is available
                if !isdefined(Main, :JuliaFormatter)
                    try
                        @eval Main using JuliaFormatter
                    catch
                        return "Error: JuliaFormatter.jl is not installed. Install it with: using Pkg; Pkg.add(\"JuliaFormatter\")"
                    end
                end

                path = get(args, "path", "")
                overwrite = get(args, "overwrite", true)
                verbose = get(args, "verbose", true)

                if isempty(path)
                    return "Error: path parameter is required"
                end

                # Make path absolute
                abs_path = isabspath(path) ? path : joinpath(pwd(), path)

                if !ispath(abs_path)
                    return "Error: Path does not exist: $abs_path"
                end

                code = """
                using JuliaFormatter

                # Only detect changes for individual files, not directories
                if isfile("$abs_path")
                    # Read the file before formatting to detect changes
                    before_content = read("$abs_path", String)

                    # Format the file
                    format_result = format("$abs_path"; overwrite=$overwrite, verbose=$verbose)

                    # Read after to see if changes were made
                    after_content = read("$abs_path", String)
                    changes_made = before_content != after_content

                    if changes_made
                        println("✅ File was reformatted: $abs_path")
                    elseif format_result
                        println("ℹ️  File was already properly formatted: $abs_path")
                    else
                        println("⚠️  Formatting completed but check for errors: $abs_path")
                    end

                    changes_made || format_result
                else
                    # For directories, just format and return result (verbose output shows individual files)
                    format("$abs_path"; overwrite=$overwrite, verbose=$verbose)
                    nothing  # Suppress output for directories
                end
                """

                execute_repllike(
                    code;
                    description = "[Formatting code at: $abs_path]",
                    quiet = false,
                )
            catch e
                "Error formatting code: $e"
            end
        end
    )

    # Optional linting tool (requires Aqua.jl)
    lint_tool = @mcp_tool(
        :lint_package,
        "Run Aqua.jl quality assurance tests on a package.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "package_name" => Dict(
                    "type" => "string",
                    "description" => "Package name to test (defaults to current project)",
                ),
            ),
            "required" => [],
        ),
        function (args)
            try
                # Check if Aqua is available
                if !isdefined(Main, :Aqua)
                    try
                        @eval Main using Aqua
                    catch
                        return "Error: Aqua.jl is not installed. Install it with: using Pkg; Pkg.add(\"Aqua\")"
                    end
                end

                pkg_name = get(args, "package_name", nothing)

                if pkg_name === nothing
                    # Use current project
                    code = """
                    using Aqua
                    # Get current project name
                    project_file = Base.active_project()
                    if project_file === nothing
                        println("❌ No active project found")
                    else
                        using Pkg
                        proj = Pkg.TOML.parsefile(project_file)
                        pkg_name = get(proj, "name", nothing)
                        if pkg_name === nothing
                            println("❌ No package name found in Project.toml")
                        else
                            println("Running Aqua tests for package: " * pkg_name)
                            # Load the package
                            Base.eval(Main, Expr(:using, Expr(:., Symbol(pkg_name))))
                            # Run Aqua tests
                            pkg_mod = Base.eval(Main, Symbol(pkg_name))
                            Aqua.test_all(pkg_mod)
                            println("✅ All Aqua tests passed for " * pkg_name)
                        end
                    end
                    """
                else
                    # Construct code with package name - build string without dollar sign interpolation
                    code =
                        "using Aqua\n" *
                        "Base.eval(Main, Expr(:using, Expr(:., Symbol(\"" *
                        pkg_name *
                        "\"))))\n" *
                        "println(\"Running Aqua tests for package: " *
                        pkg_name *
                        "\")\n" *
                        "pkg_mod = Base.eval(Main, Symbol(\"" *
                        pkg_name *
                        "\"))\n" *
                        "Aqua.test_all(pkg_mod)\n" *
                        "println(\"✅ All Aqua tests passed for " *
                        pkg_name *
                        "\")"
                end

                execute_repllike(
                    code;
                    description = "[Running Aqua quality tests]",
                    quiet = false,
                )
            catch e
                "Error running Aqua tests: $e"
            end
        end
    )

    # High-level debugging workflow tools
    open_and_breakpoint_tool = @mcp_tool(
        :open_file_and_set_breakpoint,
        """Open a file in VS Code and set a breakpoint at a specific line.

This is a convenience tool that combines file opening and breakpoint setting
into a single operation, making it easier to set up debugging.

# Arguments
- `file_path`: Absolute path to the file to open
- `line`: Line number to set the breakpoint (optional, defaults to current cursor position)

# Examples
- Open file and set breakpoint at line 42: `{"file_path": "/path/to/file.jl", "line": 42}`
- Open file (breakpoint at cursor): `{"file_path": "/path/to/file.jl"}`
""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "file_path" => Dict(
                    "type" => "string",
                    "description" => "Absolute path to the file",
                ),
                "line" => Dict(
                    "type" => "integer",
                    "description" => "Line number for breakpoint (optional)",
                ),
            ),
            "required" => ["file_path"],
        ),
        function (args)
            try
                file_path = get(args, "file_path", "")
                line = get(args, "line", nothing)

                if isempty(file_path)
                    return "Error: file_path is required"
                end

                # Make sure it's an absolute path
                abs_path =
                    isabspath(file_path) ? file_path : joinpath(pwd(), file_path)

                if !isfile(abs_path)
                    return "Error: File does not exist: $abs_path"
                end

                # Open the file using vscode.open command
                uri = "file://$abs_path"
                args_json = JSON.json([uri])
                args_encoded = HTTP.URIs.escapeuri(args_json)
                open_uri = build_vscode_uri("vscode.open"; args = args_encoded)
                trigger_vscode_uri(open_uri)

                sleep(0.5)  # Give VS Code time to open the file

                # Navigate to line if specified
                if line !== nothing
                    goto_uri = build_vscode_uri("workbench.action.gotoLine")
                    trigger_vscode_uri(goto_uri)
                    sleep(0.3)
                end

                # Set breakpoint
                bp_uri = build_vscode_uri("editor.debug.action.toggleBreakpoint")
                trigger_vscode_uri(bp_uri)

                result = "Opened $abs_path"
                if line !== nothing
                    result *= " and navigated to line $line"
                end
                result *= ", breakpoint set"

                return result
            catch e
                return "Error: $e"
            end
        end
    )

    start_debug_session_tool = @mcp_tool(
        :start_debug_session,
        """Start a debugging session in VS Code.

Opens the debug view and starts debugging with the current configuration.
Useful after setting breakpoints to begin stepping through code.

# Examples
- Start debugging: `{}`
""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        function (args)
            try
                # Open debug view
                view_uri = build_vscode_uri("workbench.view.debug")
                trigger_vscode_uri(view_uri)

                sleep(0.3)

                # Start debugging
                start_uri = build_vscode_uri("workbench.action.debug.start")
                trigger_vscode_uri(start_uri)

                return "Debug session started. Use stepping commands to navigate through code."
            catch e
                return "Error starting debug session: $e"
            end
        end
    )

    add_watch_expression_tool = @mcp_tool(
        :add_watch_expression,
        """Add a watch expression to monitor during debugging.

Watch expressions let you monitor the value of variables or expressions
as you step through code during debugging.

# Arguments
- `expression`: The Julia expression to watch (e.g., "x", "length(arr)", "myvar > 10")

# Examples
- Watch a variable: `{"expression": "x"}`
- Watch an expression: `{"expression": "length(my_array)"}`
- Watch a condition: `{"expression": "counter > 100"}`
""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "expression" => Dict(
                    "type" => "string",
                    "description" => "Expression to watch",
                ),
            ),
            "required" => ["expression"],
        ),
        function (args)
            try
                expression = get(args, "expression", "")

                if isempty(expression)
                    return "Error: expression is required"
                end

                # Focus watch view first
                watch_uri = build_vscode_uri("workbench.debug.action.focusWatchView")
                trigger_vscode_uri(watch_uri)

                sleep(0.2)

                # Add watch expression
                add_uri = build_vscode_uri("workbench.action.debug.addWatch")
                trigger_vscode_uri(add_uri)

                return "Watch expression dialog opened for: $expression (user will need to enter it)"
            catch e
                return "Error adding watch expression: $e"
            end
        end
    )

    copy_debug_value_tool = @mcp_tool(
        :copy_debug_value,
        """Copy the value of a variable or expression during debugging to the clipboard.

This tool allows AI agents to inspect variable values during a debug session.
The value is copied to the clipboard and can then be read using shell commands.

**Prerequisites:**
- Must be in an active debug session (paused at a breakpoint)
- The variable/expression must be selected or focused in the debug view

**Workflow:**
1. Focus the appropriate debug view (Variables or Watch)
2. The user or AI should have the variable selected/focused
3. Copy the value to clipboard
4. Read clipboard contents to get the value

# Arguments
- `view`: Which debug view to focus - "variables" or "watch" (default: "variables")

# Examples
- Copy from variables view: `{"view": "variables"}`
- Copy from watch view: `{"view": "watch"}`

**Note:** After copying, use a shell command to read the clipboard:
- macOS: `pbpaste`
- Linux: `xclip -selection clipboard -o` or `xsel --clipboard --output`
- Windows: `powershell Get-Clipboard`
""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "view" => Dict(
                    "type" => "string",
                    "description" => "Debug view to focus: 'variables' or 'watch'",
                    "enum" => ["variables", "watch"],
                    "default" => "variables",
                ),
            ),
            "required" => [],
        ),
        function (args)
            try
                view = get(args, "view", "variables")

                # Focus the appropriate debug view
                if view == "watch"
                    focus_uri = build_vscode_uri("workbench.debug.action.focusWatchView")
                else
                    focus_uri =
                        build_vscode_uri("workbench.debug.action.focusVariablesView")
                end
                trigger_vscode_uri(focus_uri)

                sleep(0.2)

                # Copy the selected value
                copy_uri = build_vscode_uri("workbench.action.debug.copyValue")
                trigger_vscode_uri(copy_uri)

                clipboard_cmd = if Sys.isapple()
                    "pbpaste"
                elseif Sys.islinux()
                    "xclip -selection clipboard -o (or xsel --clipboard --output)"
                elseif Sys.iswindows()
                    "powershell Get-Clipboard"
                else
                    "appropriate clipboard command for your OS"
                end

                return """Value copied to clipboard from $(view) view.
To read the value, run in terminal: $clipboard_cmd
Note: Make sure a variable is selected/focused in the debug view before copying."""
            catch e
                return "Error copying debug value: $e"
            end
        end
    )

    # Enhanced debugging tools using bidirectional communication
    debug_step_over_tool = @mcp_tool(
        :debug_step_over,
        """Step over the current line in the debugger.

Executes the current line and moves to the next line without entering function calls.
Must be in an active debug session (paused at a breakpoint).

# Examples
- `debug_step_over()`
- `debug_step_over(wait_for_response=true)` - Wait for confirmation
""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "wait_for_response" => Dict(
                    "type" => "boolean",
                    "description" => "Wait for command completion (default: false)",
                    "default" => false,
                ),
            ),
            "required" => [],
        ),
        function (args)
            try
                wait_response = get(args, "wait_for_response", false)

                if wait_response
                    result = execute_repllike(
                        """execute_vscode_command("workbench.action.debug.stepOver",
                                                  wait_for_response=true, timeout=10.0)""";
                        silent = false,
                        quiet = false,
                    )
                    return result
                else
                    trigger_vscode_uri(build_vscode_uri("workbench.action.debug.stepOver"))
                    return "Stepped over current line"
                end
            catch e
                return "Error stepping over: $e"
            end
        end
    )

    debug_step_into_tool = @mcp_tool(
        :debug_step_into,
        """Step into a function call in the debugger.

Enters the function on the current line to debug its internals.
Must be in an active debug session (paused at a breakpoint).

# Examples
- `debug_step_into()`
""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        function (args)
            try
                trigger_vscode_uri(build_vscode_uri("workbench.action.debug.stepInto"))
                return "Stepped into function"
            catch e
                return "Error stepping into: $e"
            end
        end
    )

    debug_step_out_tool = @mcp_tool(
        :debug_step_out,
        """Step out of the current function in the debugger.

Continues execution until the current function returns to its caller.
Must be in an active debug session (paused at a breakpoint).

# Examples
- `debug_step_out()`
""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        function (args)
            try
                trigger_vscode_uri(build_vscode_uri("workbench.action.debug.stepOut"))
                return "Stepped out of current function"
            catch e
                return "Error stepping out: $e"
            end
        end
    )

    debug_continue_tool = @mcp_tool(
        :debug_continue,
        """Continue execution in the debugger.

Resumes execution until the next breakpoint or program completion.
Must be in an active debug session (paused at a breakpoint).

# Examples
- `debug_continue()`
""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        function (args)
            try
                trigger_vscode_uri(build_vscode_uri("workbench.action.debug.continue"))
                return "Continued execution"
            catch e
                return "Error continuing: $e"
            end
        end
    )

    debug_stop_tool = @mcp_tool(
        :debug_stop,
        """Stop the current debug session.

Terminates the active debug session and returns to normal execution.

# Examples
- `debug_stop()`
""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        function (args)
            try
                trigger_vscode_uri(build_vscode_uri("workbench.action.debug.stop"))
                return "Debug session stopped"
            catch e
                return "Error stopping debug session: $e"
            end
        end
    )

    # Package management tools
    pkg_add_tool = @mcp_tool(
        :pkg_add,
        "Add Julia packages to the current environment (modifies Project.toml).",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "packages" => Dict(
                    "type" => "array",
                    "description" => "Array of package names to add",
                    "items" => Dict("type" => "string"),
                ),
            ),
            "required" => ["packages"],
        ),
        function (args)
            try
                packages = get(args, "packages", String[])
                if isempty(packages)
                    return "Error: packages array is required and cannot be empty"
                end

                # Use Pkg.add directly with io=devnull to disable interactivity
                pkg_names = join(["\"$p\"" for p in packages], ", ")
                code = "using Pkg; Pkg.add([$pkg_names]; io=devnull)"

                result = execute_repllike(code; silent = false, quiet = false)
                return "Added packages: $(join(packages, ", "))\n\n$result"
            catch e
                return "Error adding packages: $e"
            end
        end
    )

    pkg_rm_tool = @mcp_tool(
        :pkg_rm,
        "Remove Julia packages from the current environment.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "packages" => Dict(
                    "type" => "array",
                    "description" => "Array of package names to remove",
                    "items" => Dict("type" => "string"),
                ),
            ),
            "required" => ["packages"],
        ),
        function (args)
            try
                packages = get(args, "packages", String[])
                if isempty(packages)
                    return "Error: packages array is required and cannot be empty"
                end

                # Use Pkg.rm directly with io=devnull to disable interactivity
                pkg_names = join(["\"$p\"" for p in packages], ", ")
                code = "using Pkg; Pkg.rm([$pkg_names]; io=devnull)"

                result = execute_repllike(code; silent = false, quiet = false)
                return "Removed packages: $(join(packages, ", "))\n\n$result"
            catch e
                return "Error removing packages: $e"
            end
        end
    )

    # Create supervisor tools
    supervisor_status_tool = @mcp_tool(
        :supervisor_status,
        "Get status of all managed agents in supervisor mode.",
        Dict("type" => "object", "properties" => Dict()),
        function (args)
            if SUPERVISOR_REGISTRY[] === nothing
                return "Supervisor mode is not enabled. Start MCPRepl with supervisor=true."
            end

            registry = SUPERVISOR_REGISTRY[]
            agents = Supervisor.get_all_agents(registry)

            if isempty(agents)
                return "No agents registered."
            end

            output = "Agent Status Report\n"
            output *= "=" ^ 60 * "\n\n"

            for (name, agent) in agents
                output *= "Agent: $name\n"
                output *= "  Status: $(agent.status)\n"
                output *= "  Port: $(agent.port)\n"
                output *= "  PID: $(agent.pid === nothing ? "unknown" : agent.pid)\n"
                output *= "  Directory: $(agent.directory)\n"
                output *= "  Description: $(agent.description)\n"
                output *= "  Uptime: $(Supervisor.uptime_string(agent))\n"
                output *= "  Last Heartbeat: $(Supervisor.heartbeat_age_string(agent))\n"
                output *= "  Missed Heartbeats: $(agent.missed_heartbeats)\n"
                output *= "  Restarts: $(agent.restarts)\n"
                output *= "  Restart Policy: $(agent.restart_policy)\n"
                output *= "\n"
            end

            return output
        end
    )

    supervisor_start_agent_tool = @mcp_tool(
        :supervisor_start_agent,
        "Start a managed agent process.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "agent_name" => Dict(
                    "type" => "string",
                    "description" => "Name of the agent to start",
                ),
            ),
            "required" => ["agent_name"],
        ),
        function (args)
            if SUPERVISOR_REGISTRY[] === nothing
                return "Supervisor mode is not enabled. Start MCPRepl with supervisor=true."
            end

            agent_name = get(args, "agent_name", "")
            if isempty(agent_name)
                return "Error: agent_name is required"
            end

            registry = SUPERVISOR_REGISTRY[]
            agent = Supervisor.get_agent(registry, agent_name)

            if agent === nothing
                return "Error: Agent '$agent_name' not found in registry"
            end

            if agent.status != :stopped
                return "Agent '$agent_name' is already running (status: $(agent.status))"
            end

            success = Supervisor.start_agent(agent)

            if success
                return "Agent '$agent_name' started successfully on port $(agent.port)"
            else
                return "Failed to start agent '$agent_name'"
            end
        end
    )

    supervisor_stop_agent_tool = @mcp_tool(
        :supervisor_stop_agent,
        "Stop a managed agent process.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "agent_name" => Dict(
                    "type" => "string",
                    "description" => "Name of the agent to stop",
                ),
                "force" => Dict(
                    "type" => "boolean",
                    "description" => "Force kill the agent (default: false)",
                    "default" => false,
                ),
            ),
            "required" => ["agent_name"],
        ),
        function (args)
            if SUPERVISOR_REGISTRY[] === nothing
                return "Supervisor mode is not enabled. Start MCPRepl with supervisor=true."
            end

            agent_name = get(args, "agent_name", "")
            force = get(args, "force", false)

            if isempty(agent_name)
                return "Error: agent_name is required"
            end

            registry = SUPERVISOR_REGISTRY[]
            agent = Supervisor.get_agent(registry, agent_name)

            if agent === nothing
                return "Error: Agent '$agent_name' not found in registry"
            end

            if agent.status == :stopped
                return "Agent '$agent_name' is already stopped"
            end

            success = Supervisor.stop_agent(agent; force = force)

            if success
                return "Agent '$agent_name' stopped successfully"
            else
                return "Failed to stop agent '$agent_name'"
            end
        end
    )

    supervisor_restart_agent_tool = @mcp_tool(
        :supervisor_restart_agent,
        "Restart a managed agent process.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "agent_name" => Dict(
                    "type" => "string",
                    "description" => "Name of the agent to restart",
                ),
            ),
            "required" => ["agent_name"],
        ),
        function (args)
            if SUPERVISOR_REGISTRY[] === nothing
                return "Supervisor mode is not enabled. Start MCPRepl with supervisor=true."
            end

            agent_name = get(args, "agent_name", "")

            if isempty(agent_name)
                return "Error: agent_name is required"
            end

            registry = SUPERVISOR_REGISTRY[]
            agent = Supervisor.get_agent(registry, agent_name)

            if agent === nothing
                return "Error: Agent '$agent_name' not found in registry"
            end

            success = Supervisor.restart_agent(agent)

            if success
                return "Agent '$agent_name' restarted successfully. It should be online in a few seconds."
            else
                return "Failed to restart agent '$agent_name'"
            end
        end
    )

    # Create LSP tools
    lsp_tools = create_lsp_tools()

    # Load tools configuration
    enabled_tools = load_tools_config()

    # Collect all tools
    all_tools = [
        ping_tool,
        usage_instructions_tool,
        usage_quiz_tool,
        tool_help_tool,
        repl_tool,
        restart_repl_tool,
        vscode_command_tool,
        list_vscode_commands_tool,
        investigate_tool,
        search_methods_tool,
        macro_expand_tool,
        type_info_tool,
        profile_tool,
        list_names_tool,
        code_lowered_tool,
        code_typed_tool,
        format_tool,
        lint_tool,
        open_and_breakpoint_tool,
        start_debug_session_tool,
        add_watch_expression_tool,
        copy_debug_value_tool,
        debug_step_over_tool,
        debug_step_into_tool,
        debug_step_out_tool,
        debug_continue_tool,
        debug_stop_tool,
        pkg_add_tool,
        pkg_rm_tool,
        supervisor_status_tool,
        supervisor_start_agent_tool,
        supervisor_stop_agent_tool,
        supervisor_restart_agent_tool,
        lsp_tools...,  # Add all LSP tools
    ]

    # Filter tools based on configuration
    active_tools = filter_tools_by_config(all_tools, enabled_tools)

    # Show tool configuration status if verbose and config exists
    if verbose && enabled_tools !== nothing
        disabled_count = length(all_tools) - length(active_tools)
        if disabled_count > 0
            printstyled("🔧 Tools: ", color = :cyan, bold = true)
            println("$(length(active_tools)) enabled, $disabled_count disabled by config")
        end
    end

    # Create and start server
    println("Starting MCP server on port $actual_port...")
    SERVER[] = start_mcp_server(
        active_tools,
        actual_port;
        verbose = verbose,
        security_config = security_config,
    )
    if isdefined(Base, :active_repl)
        set_prefix!(Base.active_repl)
        # Refresh the prompt to show the new prefix and clear any leftover output
        println()  # Add newline for clean separation
        REPL.LineEdit.refresh_line(Base.active_repl.mistate)
    else
        atreplinit(set_prefix!)
    end
    nothing
end

function set_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, "✻ julia> ")
end
function unset_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
end
function get_mainmode(repl)
    only(
        filter(repl.interface.modes) do mode
            mode isa REPL.Prompt &&
                mode.prompt isa Function &&
                contains(mode.prompt(), "julia>")
        end,
    )
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")
        stop_mcp_server(SERVER[])
        SERVER[] = nothing
        if isdefined(Base, :active_repl)
            unset_prefix!(Base.active_repl) # Reset the prompt prefix
        end
    else
        println("No server running to stop.")
    end

    # Stop supervisor if running
    if SUPERVISOR_REGISTRY[] !== nothing
        println("Stopping supervisor...")
        Supervisor.stop_supervisor(SUPERVISOR_REGISTRY[]; stop_agents = true)
        SUPERVISOR_REGISTRY[] = nothing
    end
end

"""
    test_server(port::Int=3000; max_attempts::Int=3, delay::Float64=0.5)

Test if the MCP server is running and responding to REPL requests.

Attempts to connect to the server on the specified port and send a simple
exec_repl command. Returns `true` if successful, `false` otherwise.

# Arguments
- `port::Int`: The port number the MCP server is running on (default: 3000)
- `max_attempts::Int`: Maximum number of connection attempts (default: 3)
- `delay::Float64`: Delay in seconds between attempts (default: 0.5)

# Example
```julia
if MCPRepl.test_server(3000)
    println("✓ MCP Server is responding")
else
    println("✗ MCP Server is not responding")
end
```
"""
function test_server(
    port::Int = 3000;
    host = "127.0.0.1",
    max_attempts::Int = 3,
    delay::Float64 = 0.5,
)
    for attempt = 1:max_attempts
        try
            # Use HTTP.jl for a clean, proper request
            body = """{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"exec_repl","arguments":{"expression":"println(\\\"🎉 MCP Server ready!\\\")","silent":true}}}"""

            # Build headers with security if configured
            headers = Dict{String,String}("Content-Type" => "application/json")

            # Prefer explicit env var when present
            env_key = get(ENV, "JULIA_MCP_API_KEY", "")

            # Load workspace security config (if available)
            security_config = try
                load_security_config()
            catch
                nothing
            end

            auth_key = nothing

            if !isempty(env_key)
                auth_key = env_key
            elseif security_config !== nothing && security_config.mode != :lax
                # Use the first configured key, if any
                if !isempty(security_config.api_keys)
                    auth_key = first(security_config.api_keys)
                end
            end

            if auth_key !== nothing
                headers["Authorization"] = "Bearer $(auth_key)"
            end

            response = HTTP.post(
                "http://$host:$port/",
                collect(headers),
                body;
                readtimeout = 5,
                connect_timeout = 2,
            )

            # Check if we got a successful response
            if response.status == 200
                REPL.prepare_next(Base.active_repl)
                return true
            end
        catch e
            if attempt < max_attempts
                sleep(delay)
            end
        end
    end

    println("✗ MCP Server on port $port is not responding after $max_attempts attempts")
    return false
end

# ============================================================================
# Public Security Management Functions
# ============================================================================

"""
    security_status()

Display current security configuration.
"""
function security_status()
    config = load_security_config()
    if config === nothing
        printstyled("\n⚠️  No security configuration found\n", color = :yellow, bold = true)
        println("Run MCPRepl.setup_security() to configure")
        println()
        return
    end
    show_security_status(config)
end

"""
    setup_security(; force::Bool=false)

Launch the security setup wizard.
"""
function setup_security(; force::Bool = false, gentle::Bool = false)
    return security_setup_wizard(pwd(); force = force, gentle = gentle)
end

"""
    generate_key()

Generate and add a new API key to the current configuration.
"""
function generate_key()
    return add_api_key!(pwd())
end

"""
    revoke_key(key::String)

Revoke (remove) an API key from the configuration.
"""
function revoke_key(key::String)
    return remove_api_key!(key, pwd())
end

"""
    allow_ip(ip::String)

Add an IP address to the allowlist.
"""
function allow_ip(ip::String)
    return add_allowed_ip!(ip, pwd())
end

"""
    deny_ip(ip::String)

Remove an IP address from the allowlist.
"""
function deny_ip(ip::String)
    return remove_allowed_ip!(ip, pwd())
end

"""
    set_security_mode(mode::Symbol)

Change the security mode (:strict, :relaxed, or :lax).
"""
function set_security_mode(mode::Symbol)
    return change_security_mode!(mode, pwd())
end

"""
    call_tool(tool_id::Union{Symbol,String}, args::Dict)

Call an MCP tool directly from the REPL without hanging.

This helper function handles the two-parameter signature that most tools expect
(args and stream_channel), making it easier to call tools programmatically.

**Symbol-first API**: Pass symbols (e.g., `:exec_repl`) for type safety.
String names are still supported for backward compatibility.

# Examples
```julia
# Symbol-based (recommended)
MCPRepl.call_tool(:exec_repl, Dict("expression" => "2 + 2"))
MCPRepl.call_tool(:investigate_environment, Dict())
MCPRepl.call_tool(:search_methods, Dict("query" => "println"))

# String-based (deprecated, for compatibility)
MCPRepl.call_tool("exec_repl", Dict("expression" => "2 + 2"))
```

# Available Tools
Call `list_tools()` to see all available tools and their descriptions.
"""
function call_tool(tool_id::Symbol, args::Dict)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with MCPRepl.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    # Execute tool handler synchronously when called from REPL
    # This avoids deadlock when tools call execute_repllike
    try
        # Try calling with just args first (most common case)
        # If that fails with MethodError, try with streaming channel parameter
        result = try
            tool.handler(args)
        catch e
            if e isa MethodError &&
               hasmethod(tool.handler, Tuple{typeof(args),typeof(nothing)})
                # Handler supports streaming, call with both parameters
                tool.handler(args, nothing)
            else
                rethrow(e)
            end
        end
        return result
    catch e
        rethrow(e)
    end
end

# String-based overload for backward compatibility (deprecated)
function call_tool(tool_name::String, args::Dict)
    @warn "String-based tool names are deprecated. Use :$(Symbol(tool_name)) instead." maxlog=1
    tool_id = Symbol(tool_name)
    return call_tool(tool_id, args)
end

function call_tool(tool_id::Symbol, args::Pair{Symbol,String}...)
    return call_tool(tool_id, Dict([String(k) => v for (k, v) in args]))
end

"""
    list_tools()

List all available MCP tools with their names and descriptions.

Returns a dictionary mapping tool names to their descriptions.
"""
function list_tools()
    if SERVER[] === nothing
        error("MCP server is not running. Start it with MCPRepl.start!()")
    end

    server = SERVER[]
    tools_info = Dict{Symbol,String}()

    for (id, tool) in server.tools
        tools_info[id] = tool.description
    end

    # Print formatted output
    println("\n📚 Available MCP Tools")
    println("="^70)
    println()

    for (name, desc) in sort(collect(tools_info))
        printstyled("  • ", name, "\n", color = :cyan, bold = true)
        # Print first line of description
        first_line = split(desc, "\n")[1]
        println("    ", first_line)
        println()
    end

    return tools_info
end

"""
    tool_help(tool_id::Symbol)
Get detailed help/documentation for a specific MCP tool.
"""
function tool_help(tool_id::Symbol; extended::Bool = false)
    if SERVER[] === nothing
        error("MCP server is not running. Start it with MCPRepl.start!()")
    end

    server = SERVER[]
    if !haskey(server.tools, tool_id)
        error("Tool :$tool_id not found. Call list_tools() to see available tools.")
    end

    tool = server.tools[tool_id]

    println("\n📖 Help for MCP Tool :$tool_id")
    println("="^70)
    println()
    println(tool.description)
    println()

    # Try to load extended documentation if requested
    if extended
        extended_help_path =
            joinpath(dirname(dirname(@__FILE__)), "extended-help", "$(string(tool_id)).md")

        if isfile(extended_help_path)
            println("\n" * "="^70)
            println("Extended Documentation")
            println("="^70)
            println()
            println(read(extended_help_path, String))
        else
            println("(No extended documentation available for this tool)")
        end
    end

    return tool
end

# Export public API functions
export start!, stop!, setup, test_server, reset
export setup_security, security_status, generate_key, revoke_key
export allow_ip, deny_ip, set_security_mode, quick_setup, gentle_setup
export call_tool, list_tools, tool_help
export Generate  # Project template generator module

end #module
