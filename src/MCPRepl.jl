module MCPRepl

using REPL
using JSON3
using InteractiveUtils
using Profile

include("MCPServer.jl")
include("setup.jl")

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

function execute_repllike(
    str;
    silent::Bool = false,
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

    # Capture stdout/stderr during execution
    captured_output = Pipe()
    response = redirect_stdout(captured_output) do
        redirect_stderr(captured_output) do
            r = REPL.eval_on_backend(expr, backend)
            close(Base.pipe_writer(captured_output))
            r
        end
    end
    captured_content = read(captured_output, String)

    # Only reshow output if not silent
    if !silent
        print(captured_content)
    end

    disp = IOBufferDisplay()

    # generate printout, err goest to disp.err, val goes to "specialdisplay" disp
    REPL.print_response(
        disp.io,
        response,
        backend,
        !REPL.ends_with_semicolon(str),
        false,
        disp,
    )

    # generate the printout again for the "normal" repl (only if not silent)
    if !silent
        REPL.print_response(repl, response, !REPL.ends_with_semicolon(str), repl.hascolor)
    end

    REPL.prepare_next(repl)

    if !silent
        REPL.LineEdit.refresh_line(repl.mistate)
    end

    # Combine captured output with display output
    display_content = String(take!(disp.io))

    return captured_content * display_content
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

function start!(; port = 3000, verbose::Bool = true)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    usage_instructions_tool = MCPTool(
        "usage_instructions",
        "Get detailed instructions for proper Julia REPL usage, best practices, and workflow guidelines for AI agents.",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        args -> begin
            try
                workflow_path = joinpath(
                    dirname(dirname(@__FILE__)),
                    "prompts",
                    "julia_repl_workflow.md",
                )
                if isfile(workflow_path)
                    return read(workflow_path, String)
                else
                    return "Error: julia_repl_workflow.md not found at $workflow_path"
                end
            catch e
                return "Error reading usage instructions: $e"
            end
        end,
    )

    repl_tool = MCPTool(
        "exec_repl",
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
            ),
            "required" => ["expression"],
        ),
        args -> begin
            try
                silent = get(args, "silent", false)
                execute_repllike(get(args, "expression", ""); silent = silent)
            catch e
                println("Error during execute_repllike", e)
                "Apparently there was an **internal** error to the MCP server: $e"
            end
        end,
    )

    whitespace_tool = MCPTool(
        "remove-trailing-whitespace",
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
        end,
    )

    investigate_tool = MCPTool(
        "investigate_environment",
        """Investigate the current Julia environment including pwd, active project, packages, and development packages with their paths.

        This tool provides comprehensive information about:
        - Current working directory
        - Active project and its details
        - All packages in the environment with development status
        - Development packages with their file system paths
        - Current environment package status
        - Revise.jl status for hot reloading

        This is useful for understanding the development setup and debugging environment issues.""",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        args -> begin
            try
                execute_repllike("MCPRepl.repl_status_report()")
            catch e
                "Error investigating environment: $e"
            end
        end,
    )

    search_methods_tool = MCPTool(
        "search_methods",
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
        end,
    )

    macro_expand_tool = MCPTool(
        "macro_expand",
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
        end,
    )

    type_info_tool = MCPTool(
        "type_info",
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
                "Error getting type info: \$e"
            end
        end,
    )

    profile_tool = MCPTool(
        "profile_code",
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
        end,
    )

    list_names_tool = MCPTool(
        "list_names",
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
        end,
    )

    code_lowered_tool = MCPTool(
        "code_lowered",
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
        end,
    )

    code_typed_tool = MCPTool(
        "code_typed",
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
        end,
    )

    # Create and start server
    println("Starting MCP server on port $port...")
    SERVER[] = start_mcp_server(
        [
            usage_instructions_tool,
            repl_tool,
            whitespace_tool,
            investigate_tool,
            search_methods_tool,
            macro_expand_tool,
            type_info_tool,
            profile_tool,
            list_names_tool,
            code_lowered_tool,
            code_typed_tool,
        ],
        port;
        verbose = verbose,
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
if MCPRepl.test_server(3003)
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

            response = HTTP.post(
                "http://$host:$port/",
                ["Content-Type" => "application/json"],
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

end #module
