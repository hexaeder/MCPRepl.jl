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
    
    return esc(quote
        $MCPRepl.MCPTool(
            $(QuoteNode(id_sym)),    # :exec_repl
            $name_str,                # "exec_repl"
            $description,
            $params,
            $handler
        )
    end)
end

include("security.jl")
include("security_wizard.jl")
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

function execute_repllike(
    str;
    silent::Bool = false,
    description::Union{String,Nothing} = nothing,
    stream_channel::Union{Nothing,Channel{String}} = nothing,
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
    # expr = Meta.parse(str)
    expr = Base.parse_input_line(str)
    backend = repl.backendref

    REPL.prepare_next(repl)

    # Only print the agent prompt if not silent
    if !silent
        printstyled("\nagent> ", color = :red, bold = :true)
        # If description provided, show that instead of raw code
        if description !== nothing
            println(description)
        else
            print(str, "\n")
        end
    end

    # If streaming is enabled, send progress updates through the channel
    if stream_channel !== nothing
        # Streaming mode - use separate REPL backend with line-by-line output forwarding

        # Send initial "started" event
        start_event = Dict(
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => Dict("progress" => 0, "message" => "Execution started..."),
        )
        put!(stream_channel, JSON.json(start_event))

        # Save original streams
        orig_stdout = stdout
        orig_stderr = stderr

        # Create pipes for redirection
        stdout_reader, stdout_writer = redirect_stdout()
        stderr_reader, stderr_writer = redirect_stderr()

        # Buffers for final capture
        stdout_buf = IOBuffer()
        stderr_buf = IOBuffer()

        # Helper to process and forward output line by line
        function forward_output(reader, original_stream, buffer, stream_name)
            line_buffer = IOBuffer()

            try
                while isopen(reader)
                    # Read available data
                    data = readavailable(reader)
                    if !isempty(data)
                        # Write to original stream (real-time display)
                        write(original_stream, data)
                        flush(original_stream)

                        # Write to capture buffer
                        write(buffer, data)

                        # Process line by line for SSE streaming
                        write(line_buffer, data)

                        # Extract complete lines
                        seekstart(line_buffer)
                        while !eof(line_buffer)
                            line = readline(line_buffer; keep = true)
                            if endswith(line, '\n')
                                # Complete line - send via SSE
                                try
                                    output_event = Dict(
                                        "jsonrpc" => "2.0",
                                        "method" => "notifications/message",
                                        "params" => Dict(
                                            "level" => stream_name,
                                            "message" => line,
                                        ),
                                    )
                                    put!(stream_channel, JSON.json(output_event))
                                catch e
                                    @warn "SSE streaming error" exception = e
                                end
                            else
                                # Incomplete line - save back to buffer
                                new_buffer = IOBuffer()
                                write(new_buffer, line)
                                line_buffer = new_buffer
                                break
                            end
                        end
                    end
                    sleep(0.001) # Small yield
                end

                # Flush any remaining partial line
                remaining = String(take!(line_buffer))
                if !isempty(remaining)
                    try
                        output_event = Dict(
                            "jsonrpc" => "2.0",
                            "method" => "notifications/message",
                            "params" =>
                                Dict("level" => stream_name, "message" => remaining),
                        )
                        put!(stream_channel, JSON.json(output_event))
                    catch e
                        @warn "SSE streaming error on final flush" exception = e
                    end
                end
            catch e
                if !isa(e, EOFError)
                    @warn "Output forwarding error for $stream_name" exception = e
                end
            end
        end

        # Start async tasks to forward output
        stdout_task = @async forward_output(stdout_reader, orig_stdout, stdout_buf, "info")
        stderr_task = @async forward_output(stderr_reader, orig_stderr, stderr_buf, "error")

        # Evaluate using the backend
        response = try
            REPL.eval_on_backend(expr, backend)
        catch e
            error_event = Dict(
                "jsonrpc" => "2.0",
                "method" => "notifications/progress",
                "params" => Dict("progress" => 100, "message" => "Error: $e"),
            )
            put!(stream_channel, JSON.json(error_event))
            e
        finally
            # Restore stdout/stderr
            redirect_stdout(orig_stdout)
            redirect_stderr(orig_stderr)

            # Close readers to stop tasks
            close(stdout_reader)
            close(stderr_reader)

            # Wait for forwarding tasks to finish
            sleep(0.1)
            wait(stdout_task)
            wait(stderr_task)
        end

        # Get captured content
        captured_content = String(take!(stdout_buf))
        stderr_content = String(take!(stderr_buf))
        if !isempty(stderr_content)
            captured_content = captured_content * "\n" * stderr_content
        end

        # Send completion notification
        complete_event = Dict(
            "jsonrpc" => "2.0",
            "method" => "notifications/progress",
            "params" => Dict("progress" => 100, "message" => "Execution complete"),
        )
        put!(stream_channel, JSON.json(complete_event))
    else
        # Non-streaming mode (original behavior)
        captured_output = Pipe()

        # Always use direct evaluation to avoid deadlock when called from REPL
        # The backend task approach causes issues when tools are called interactively
        response = redirect_stdout(captured_output) do
            redirect_stderr(captured_output) do
                try
                    r = Core.eval(Main, expr)
                    close(Base.pipe_writer(captured_output))
                    r
                catch e
                    close(Base.pipe_writer(captured_output))
                    # Rethrow to handle error properly
                    rethrow(e)
                end
            end
        end

        captured_content = read(captured_output, String)

        # Only reshow output if not silent
        if !silent
            print(captured_content)
        end
        
        # Format the result for display
        result_str = if !REPL.ends_with_semicolon(str)
            # Show the result value
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

    usage_instructions_tool = @mcp_tool :usage_instructions "Get detailed instructions for proper Julia REPL usage, best practices, and workflow guidelines for AI agents." Dict(
        "type" => "object",
        "properties" => Dict(),
        "required" => []
    ) (args -> begin
            try
                workflow_path = joinpath(
                    dirname(dirname(@__FILE__)),
                    "prompts",
                    "julia_repl_workflow.md",
                )
                commands_json_path = joinpath(
                    dirname(dirname(@__FILE__)),
                    "prompts",
                    "vscode_commands.json",
                )

                if !isfile(workflow_path)
                    return "Error: julia_repl_workflow.md not found at $workflow_path"
                end

                base_content = read(workflow_path, String)

                # Try to read actual allowed commands from workspace settings and format with descriptions
                try
                    settings = read_vscode_settings()
                    allowed_commands = get(
                        settings,
                        "vscode-remote-control.allowedCommands",
                        nothing,
                    )

                    if allowed_commands !== nothing && !isempty(allowed_commands)
                        # Load command documentation
                        command_docs = Dict{String,String}()
                        command_categories =
                            Dict{String,Tuple{String,Vector{String}}}()  # category_id => (name, commands)

                        if isfile(commands_json_path)
                            try
                                commands_data = JSON.parse(
                                    read(
                                        commands_json_path,
                                        String;
                                        dicttype = Dict{String,Any},
                                    ),
                                )
                                categories = get(commands_data, :categories, Dict())

                                # Build lookup table and category mapping
                                for (cat_id, cat_data) in pairs(categories)
                                    cat_name = get(cat_data, :name, string(cat_id))
                                    cat_commands = String[]

                                    cmds = get(cat_data, :commands, Dict())
                                    for (cmd, desc) in pairs(cmds)
                                        command_docs[string(cmd)] = string(desc)
                                        push!(cat_commands, string(cmd))
                                    end

                                    command_categories[string(cat_id)] =
                                        (cat_name, cat_commands)
                                end
                            catch e
                                @debug "Could not load command documentation" exception =
                                    e
                            end
                        end

                        # Append formatted commands section
                        commands_section = "\n\n---\n\n## Currently Configured VS Code Commands\n\n"
                        commands_section *= "Your workspace has **$(length(allowed_commands)) commands** configured in `.vscode/settings.json`.\n\n"

                        # Group commands by category
                        categorized_commands = Dict{String,Vector{String}}()
                        uncategorized_commands = String[]

                        for cmd in allowed_commands
                            cmd_str = string(cmd)
                            found_category = false

                            for (cat_id, (cat_name, cat_cmds)) in command_categories
                                if cmd_str in cat_cmds
                                    if !haskey(categorized_commands, cat_id)
                                        categorized_commands[cat_id] = String[]
                                    end
                                    push!(categorized_commands[cat_id], cmd_str)
                                    found_category = true
                                    break
                                end
                            end

                            if !found_category
                                push!(uncategorized_commands, cmd_str)
                            end
                        end

                        # Output categorized commands
                        category_order = [
                            "julia",
                            "file",
                            "navigation",
                            "window",
                            "terminal",
                            "search",
                            "git",
                            "debug",
                            "tasks",
                            "extensions",
                            "vscode_api",
                        ]

                        for cat_id in category_order
                            if haskey(categorized_commands, cat_id)
                                cat_name, _ = command_categories[cat_id]
                                commands_section *= "### $(cat_name)\n\n"

                                for cmd in sort(categorized_commands[cat_id])
                                    desc = get(command_docs, cmd, "No description available")
                                    commands_section *= "- **`$(cmd)`** - $(desc)\n"
                                end

                                commands_section *= "\n"
                            end
                        end

                        # Output uncategorized commands
                        if !isempty(uncategorized_commands)
                            commands_section *= "### 📋 Other Commands\n\n"
                            for cmd in sort(uncategorized_commands)
                                desc = get(command_docs, cmd, "No description available")
                                commands_section *= "- **`$(cmd)`** - $(desc)\n"
                            end
                            commands_section *= "\n"
                        end

                        return base_content * commands_section
                    end
                catch e
                    # If reading settings fails, just return base content
                    @debug "Could not read VS Code settings for allowed commands" exception =
                        e
                end
                return base_content
            catch e
                return "Error reading usage instructions: $e"
            end
        end
    )

    repl_tool = @mcp_tool(:exec_repl,
                """
        Execute Julia code in a shared, persistent REPL session to avoid startup latency.

        **PREREQUISITE**: Before using this tool, you MUST first call the `usage_instructions` tool to understand proper Julia REPL workflow, best practices, and etiquette for shared REPL usage.

        Once this function is available, **never** use `julia` commands in bash, always use the REPL.

        The tool returns raw text output containing: all printed content from stdout and stderr streams, plus the mime text/plain representation of the expression's return value (unless the expression ends with a semicolon).

        You may use this REPL to
        - execute julia code
        - execute test sets
        - get julia function documentation (i.e. send @doc functionname)
        - investigate the environment (use investigate_environment tool for comprehensive setup info)
        """,
        Dict(
            "type" => "object",
            "properties" => Dict(
                "expression" => Dict(
                    "type" => "string",
                    "description" => "Julia expression to evaluate (e.g., '2 + 3 * 4' or `import Pkg; Pkg.status()`)",
                ),
                "silent" => Dict(
                    "type" => "boolean",
                    "description" => "If true, suppress the 'agent>' prompt and output display (default: false)",
                ),
                "stream" => Dict(
                    "type" => "boolean",
                    "description" => "If true, enable real-time streaming of output via SSE (default: false)",
                ),
            ),
            "required" => ["expression"],
        ),
        (args, stream_channel = nothing) -> begin
            try
                silent = get(args, "silent", false)
                execute_repllike(
                    get(args, "expression", "");
                    silent = silent,
                    stream_channel = stream_channel,
                )
            catch e
                println("Error during execute_repllike", e)
                "Apparently there was an **internal** error to the MCP server: $e"
            end
        end
    )

    restart_repl_tool = @mcp_tool(:restart_repl,
                """Restart the Julia REPL and return immediately.

        **Workflow for AI Agents:**
        1. Call this tool to trigger the restart
        2. Wait 5-10 seconds (don't make any MCP requests during this time)
        3. Try your next request - if it fails, wait a bit longer and retry

        The MCP server connection will be interrupted during restart. This is expected.
        The tool returns immediately, and you (the AI agent) must wait before making
        new requests to allow the Julia REPL to restart and the MCP server to reinitialize.

        Typical restart time is 5-10 seconds depending on system load and package precompilation.

        Use this tool after making changes to the MCP server code or when the REPL needs a fresh start.""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        (args, stream_channel = nothing) -> begin
            try
                # Get the current server port (before restart)
                server_port = SERVER[] !== nothing ? SERVER[].port : 3000

                # Execute the restart command using the vscode URI trigger
                restart_uri = build_vscode_uri(
                    "language-julia.restartREPL";
                    mcp_port = server_port,
                )
                trigger_vscode_uri(restart_uri)

                # Return immediately - the server will be restarting
                return "✓ Julia REPL restart initiated on port $server_port.\n\n⏳ Typical restart time: 5-10 seconds. Waiting for restart to complete...\n\n(The AI agent should not make any MCP requests during this waiting period.)"
            catch e
                return "Error initiating REPL restart: $e"
            end
        end
    )

    whitespace_tool = @mcp_tool(:remove_trailing_whitespace,
                """Remove trailing whitespace from all lines in a file.

        This tool should be called to clean up any trailing spaces that AI agents tend to leave in files after editing.

        **Usage Guidelines:**
        - For single file edits: Call immediately after editing the file
        - For multiple file edits: Call once on each modified file at the very end, before handing back to the user
        - Always call this tool on files you've edited to maintain clean, professional code formatting

        The tool efficiently removes all types of trailing whitespace (spaces, tabs, mixed) from every line in the file.""",
        MCPRepl.text_parameter("file_path", "Absolute path to the file to clean up"),
        args -> begin
            try
                file_path = get(args, "file_path", "")
                if isempty(file_path)
                    return "Error: file_path parameter is required"
                end

                if !isfile(file_path)
                    return "Error: File does not exist: $file_path"
                end

                # Use sed to remove trailing whitespace (similar to emacs delete-trailing-whitespace)
                # This removes all trailing whitespace characters from each line
                result = run(
                    pipeline(`sed -i 's/[[:space:]]*$//' $file_path`, stderr = devnull),
                )

                if result.exitcode == 0
                    return "Successfully removed trailing whitespace from $file_path"
                else
                    return "Error: Failed to remove trailing whitespace from $file_path"
                end
            catch e
                return "Error removing trailing whitespace: $e"
            end
        end
    )

    vscode_command_tool = @mcp_tool(:execute_vscode_command,
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
        execute_vscode_command("language-julia.restartREPL")
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

    investigate_tool = @mcp_tool(:investigate_environment,
                """Investigate the current Julia environment including pwd, active project, packages, and development packages with their paths.

        This tool provides comprehensive information about:
        - Current working directory
        - Active project and its details
        - All packages in the environment with development status
        - Development packages with their file system paths
        - Current environment package status
        - Revise.jl status for hot reloading

        This is useful for understanding the development setup and debugging environment issues.

        **Tip:** If you need to restart the Julia REPL (e.g., when Revise isn't tracking changes properly),
        use the execute_vscode_command tool with "language-julia.restartREPL".""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        args -> begin
            try
                execute_repllike("MCPRepl.repl_status_report()")
            catch e
                "Error investigating environment: $e"
            end
        end
    )

    search_methods_tool = @mcp_tool(:search_methods,
                """Search for all methods of a function or all methods matching a type signature.

        This is essential for understanding Julia's multiple dispatch system and finding
        what methods are available for a function.

        # Examples
        - Find all methods: `search_methods(println)`
        - Find methods by signature: `methodswith(String)`
        - Find methods in a module: `names(Module, all=true)`

        Returns a formatted list of all matching methods with their signatures.""",
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
                execute_repllike(code; description = "[Searching methods for: $query]")
            catch e
                "Error searching methods: \$e"
            end
        end
    )

    macro_expand_tool = @mcp_tool(:macro_expand,
                """Expand a macro to see what code it generates.

        This is invaluable for understanding what macros do and debugging macro-heavy code.

        # Examples
        - `@macroexpand @time sleep(1)`
        - `@macroexpand @test 1 + 1 == 2`
        - `@macroexpand @inbounds a[i]`

        Returns the expanded code that the macro generates.""",
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
                execute_repllike(code; description = "[Expanding macro: $expr]")
            catch e
                "Error expanding macro: \$e"
            end
        end
    )

    type_info_tool = @mcp_tool(:type_info,
                """Get comprehensive information about a Julia type.

        Provides details about:
        - Type hierarchy (supertypes and subtypes)
        - Field names and types
        - Type parameters
        - Whether it's abstract, primitive, or concrete

        # Examples
        - `type_info(String)`
        - `type_info(Vector{Int})`
        - `type_info(AbstractArray)`

        This is essential for understanding Julia's type system.""",
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
                execute_repllike(code; description = "[Getting type info for: $type_expr]")
            catch e
                "Error getting type info: $e"
            end
        end
    )

    profile_tool = @mcp_tool(:profile_code,
                """Profile Julia code to identify performance bottlenecks.

        Uses Julia's built-in Profile stdlib to analyze where time is spent in your code.

        # Example
        ```julia
        profile_code(\"\"\"
            function test()
                sum = 0
                for i in 1:1000000
                    sum += i
                end
                sum
            end
            test()
        \"\"\")
        ```

        Returns a profile report showing which lines take the most time.""",
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
                execute_repllike(wrapper; description = "[Profiling code]")
            catch e
                "Error profiling code: \$e"
            end
        end
    )

    list_names_tool = @mcp_tool(:list_names,
                """List all exported names in a module or package.

        Useful for discovering what functions, types, and constants are available
        in a module without reading documentation.

        # Examples
        - `list_names(Base)`
        - `list_names(Core)`
        - `list_names(MyPackage)`

        Set all=true to include non-exported names.""",
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
                execute_repllike(code; description = "[Listing names in: $module_name]")
            catch e
                "Error listing names: \$e"
            end
        end
    )

    code_lowered_tool = @mcp_tool(:code_lowered,
                """Show lowered (desugared) Julia code for a function.

        This shows the intermediate representation after syntax desugaring but before
        type inference. Useful for understanding what Julia does with your code.

        # Example
        - `code_lowered(sin, (Float64,))`
        - `code_lowered(+, (Int, Int))`

        Requires function name and tuple of argument types.""",
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
                )
            catch e
                "Error getting lowered code: \$e"
            end
        end
    )

    code_typed_tool = @mcp_tool(:code_typed,
                """Show type-inferred Julia code for a function.

        This shows the code after type inference, which is crucial for understanding
        performance. Type-unstable code will show up here with Union or Any types.

        # Example
        - `code_typed(sin, (Float64,))`
        - `code_typed(+, (Int, Int))`

        Useful for debugging type stability and performance issues.""",
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
                )
            catch e
                "Error getting typed code: \$e"
            end
        end
    )

    # Optional formatting tool (requires JuliaFormatter.jl)
    format_tool = @mcp_tool(:format_code,
                """Format Julia code using JuliaFormatter.jl (optional).

        Formats Julia source files or directories according to standard style guidelines.
        This tool requires JuliaFormatter.jl to be installed in your environment.

        # Arguments
        - `path`: Path to a Julia file or directory to format
        - `overwrite`: Whether to overwrite files in place (default: true)
        - `verbose`: Show which files are being formatted (default: true)

        # Installation
        If JuliaFormatter is not installed, add it with:
        ```julia
        using Pkg; Pkg.add("JuliaFormatter")
        ```

        # Examples
        - Format a single file: `{"path": "src/MyModule.jl"}`
        - Format entire src directory: `{"path": "src"}`
        - Preview without overwriting: `{"path": "src/file.jl", "overwrite": false}`
        """,
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
                """

                execute_repllike(code; description = "[Formatting code at: $abs_path]")
            catch e
                "Error formatting code: $e"
            end
        end
    )

    # Optional linting tool (requires Aqua.jl)
    lint_tool = @mcp_tool(:lint_package,
                """Run Aqua.jl quality assurance tests on a Julia package (optional).

        Performs comprehensive package quality checks including:
        - Ambiguity detection in method signatures
        - Undefined exports
        - Unbound type parameters
        - Dependency analysis
        - Project.toml validation
        - And more

        This tool requires Aqua.jl to be installed in your environment.

        # Arguments
        - `package_name`: Name of the package to test (default: current project)

        # Installation
        If Aqua is not installed, add it with:
        ```julia
        using Pkg; Pkg.add("Aqua")
        ```

        # Examples
        - Test current package: `{}`
        - Test specific package: `{"package_name": "MyPackage"}`
        """,
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
                            println("Running Aqua tests for package: \$pkg_name")
                            # Load the package
                            @eval using \$(Symbol(pkg_name))
                            # Run Aqua tests
                            Aqua.test_all(\$(Symbol(pkg_name)))
                            println("✅ All Aqua tests passed for \$pkg_name")
                        end
                    end
                    """
                else
                    code = """
                    using Aqua
                    using $pkg_name
                    println("Running Aqua tests for package: $pkg_name")
                    Aqua.test_all($pkg_name)
                    println("✅ All Aqua tests passed for $pkg_name")
                    """
                end

                execute_repllike(code; description = "[Running Aqua quality tests]")
            catch e
                "Error running Aqua tests: $e"
            end
        end
    )

    # High-level debugging workflow tools
    open_and_breakpoint_tool = @mcp_tool(:open_file_and_set_breakpoint,
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

    start_debug_session_tool = @mcp_tool(:start_debug_session,
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

    add_watch_expression_tool = @mcp_tool(:add_watch_expression,
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

    quick_file_open_tool = @mcp_tool(:quick_open_file,
                """Quickly open a file using VS Code's quick open (Cmd+P/Ctrl+P).

        Opens the quick file picker, allowing navigation to files by name.
        This is faster than navigating through the file explorer for known files.

        # Examples
        - Open quick picker: `{}`
        """,
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        function (args)
            try
                quick_uri = build_vscode_uri("workbench.action.quickOpen")
                trigger_vscode_uri(quick_uri)

                return "Quick open dialog opened (user will type filename)"
            catch e
                return "Error opening quick open: $e"
            end
        end
    )

    copy_debug_value_tool = @mcp_tool(:copy_debug_value,
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
    debug_step_over_tool = @mcp_tool(:debug_step_over,
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

    debug_step_into_tool = @mcp_tool(:debug_step_into,
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

    debug_step_out_tool = @mcp_tool(:debug_step_out,
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

    debug_continue_tool = @mcp_tool(:debug_continue,
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

    debug_stop_tool = @mcp_tool(:debug_stop,
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
    pkg_add_tool = @mcp_tool(:pkg_add,
                """Add one or more Julia packages to the current environment.

        This is a convenience wrapper around Pkg.add() that provides better
        feedback and error handling for AI agents.

        **Note**: This modifies Project.toml. For more control, agents can
        directly edit Project.toml and run Pkg.instantiate().

        # Arguments
        - `packages`: Array of package names to add (e.g., ["DataFrames", "Plots"])

        # Examples
        - `pkg_add(packages=["DataFrames"])`
        - `pkg_add(packages=["Plots", "StatsPlots"])`
        """,
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

                pkg_names = join(["\"$p\"" for p in packages], ", ")
                code = "using Pkg; Pkg.add([$pkg_names])"

                result = execute_repllike(code; silent = false)
                return "Added packages: $(join(packages, ", "))\n\n$result"
            catch e
                return "Error adding packages: $e"
            end
        end
    )

    pkg_rm_tool = @mcp_tool(:pkg_rm,
                """Remove one or more Julia packages from the current environment.

        # Arguments
        - `packages`: Array of package names to remove

        # Examples
        - `pkg_rm(packages=["OldPackage"])`
        - `pkg_rm(packages=["Package1", "Package2"])`
        """,
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

                pkg_names = join(["\"$p\"" for p in packages], ", ")
                code = "using Pkg; Pkg.rm([$pkg_names])"

                result = execute_repllike(code; silent = false)
                return "Removed packages: $(join(packages, ", "))\n\n$result"
            catch e
                return "Error removing packages: $e"
            end
        end
    )

    # Create LSP tools
    lsp_tools = create_lsp_tools()

    # Create and start server
    println("Starting MCP server on port $actual_port...")
    SERVER[] = start_mcp_server(
        [
            usage_instructions_tool,
            repl_tool,
            restart_repl_tool,
            whitespace_tool,
            vscode_command_tool,
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
            quick_file_open_tool,
            copy_debug_value_tool,
            debug_step_over_tool,
            debug_step_into_tool,
            debug_step_out_tool,
            debug_continue_tool,
            debug_stop_tool,
            pkg_add_tool,
            pkg_rm_tool,
            lsp_tools...,  # Add all LSP tools
        ],
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
        end
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
            env_key = get(ENV, "MCPREPL_API_KEY", "")

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
            if e isa MethodError && hasmethod(tool.handler, Tuple{typeof(args), typeof(nothing)})
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
    return call_tool(tool_id, Dict([String(k) => v for (k,v) in args]))
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
function tool_help(tool_id::Symbol)
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

    return tool
end

# Export public API functions
export start!, stop!, setup, test_server, reset
export setup_security, security_status, generate_key, revoke_key
export allow_ip, deny_ip, set_security_mode, quick_setup, gentle_setup
export call_tool, list_tools, tool_help
export Generate  # Project template generator module

end #module
