
module MCPRepl

using REPL
using JSON
using InteractiveUtils
using Profile
using HTTP
using Random
using SHA
using Dates
using Coverage
using ReTest
using CodeTracking
using Pkg

export @mcp_tool, MCPTool
export start!, stop!, test_server

include("tools.jl")

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
            MCPTool(
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
include("repl_status.jl")
include("tool_definitions.jl")
include("MCPServer.jl")
include("setup.jl")
include("vscode.jl")
include("lsp.jl")
include("lsp_tool_definitions.jl")
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
function remove_println_calls(expr, toplevel::Bool=true)
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
            if (func isa Expr && func.head == :. &&
                length(func.args) >= 2 &&
                func.args[end] isa QuoteNode &&
                func.args[end].value in print_funcs)
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
                logging_macros = [Symbol("@error"), Symbol("@debug"), Symbol("@info"), Symbol("@warn")]
                if macro_name in logging_macros
                    return nothing
                end
                # Also handle qualified logging macros
                if (macro_name isa Expr && macro_name.head == :. &&
                    length(macro_name.args) >= 2 &&
                    macro_name.args[end] isa QuoteNode &&
                    macro_name.args[end].value in [:error, :debug, :info, :warn])
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
ALL_TOOLS = Ref{Union{Nothing,Vector{MCPTool}}}(nothing)

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
    filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})

Filter tools from ALL_TOOLS based on the enabled tools set.
If enabled_tools is `nothing`, returns all tools (backward compatibility).
"""
function filter_tools_by_config(enabled_tools::Union{Set{Symbol},Nothing})
    if enabled_tools === nothing
        return ALL_TOOLS[]
    end

    return filter(tool -> tool.id in enabled_tools, ALL_TOOLS[])
end

function start!(;
    port::Union{Int,Nothing} = nothing,
    verbose::Bool = true,
    security_mode::Union{Symbol,Nothing} = nothing,
)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    # Load or prompt for security configuration
    security_config = load_security_config()

    if security_config === nothing
        printstyled("\n⚠️  NO SECURITY CONFIGURATION FOUND\n", color = :red, bold = true)
        println()
        println("MCPRepl requires security configuration before starting.")
        println("Run MCPRepl.setup() to configure API keys and security settings.")
        println()
        error("Security configuration required. Run MCPRepl.setup() first.")
    end

    # Determine port: priority is ENV var > function arg > config file
    actual_port = if haskey(ENV, "JULIA_MCP_PORT")
        parse(Int, ENV["JULIA_MCP_PORT"])
    elseif port !== nothing
        port
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
    # Create LSP tools
    lsp_tools = create_lsp_tools()

    # Load tools configuration
    enabled_tools = load_tools_config()

    # Collect all tools
    all_tools =[
        ping_tool,
        usage_instructions_tool,
        usage_quiz_tool,
        tool_help_tool,
        repl_tool,
        manage_repl_tool,
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
        run_tests_tool,
        lsp_tools...,  # Add all LSP tools
    ]

    MCPRepl.ALL_TOOLS[] = all_tools

    # Filter tools based on configuration
    active_tools = filter_tools_by_config(enabled_tools)

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
        extended_help_path = joinpath(
            dirname(dirname(@__FILE__)),
            "extended-help",
            "$(string(tool_id)).md",
        )

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

function restart()
    call_tool(:manage_repl, Dict("command" => "restart"))
end
function shutdown()
    call_tool(:manage_repl, Dict("command" => "shutdown"))
end

# Export public API functions
export start!, stop!, setup, test_server, reset
export setup_security, security_status, generate_key, revoke_key
export allow_ip, deny_ip, set_security_mode, quick_setup, gentle_setup
export call_tool, list_tools, tool_help
export Generate  # Project template generator module

end #module
