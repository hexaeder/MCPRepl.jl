module MCPRepl

using REPL
using HTTP
using JSON3

include("MCPServer.jl")
include("setup.jl")

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

function execute_repllike(str)
    # Check for Pkg.activate usage
    if contains(str, "activate(") && !contains(str, r"#.*overwrite no-activate-rule")
        return """
            ERROR: Using Pkg.activate to change environments is not allowed.
            You should assume you are in the correct environment for your tasks.
            You may use Pkg.status() to see the current environment and available packages.
            If you need to use a third-party 'activate' function, add '# overwrite no-activate-rule' at the end of your command.
        """
    end
    if contains(str, "Pkg.add(")
        return """
            ERROR: Using Pkg.add to install packages is not allowed.
            You should assume all necessary packages are already installed in the environment.
            If you need another package, prompt the user!
        """
    end
    # Check for varinfo() usage which is slow and problematic
    if contains(str, "varinfo(")
        return """
            ERROR: Using varinfo() is not allowed because it takes too long to execute.
            Use the investigate_environment tool instead to get information about the Julia environment.
            If unclear, ask the user.
        """
    end
    # eval using/import to suppress interactive ask for instllation
    if contains(str, r"(^|\n)using\s") || contains(str, r"(^|\n)import\s")
        # Replace each import/using statement with @eval prefix
        str = replace(str, r"(^|\n)(using\s[^\n]*)" => s"\1@eval \2")
        str = replace(str, r"(^|\n)(import\s[^\n]*)" => s"\1@eval \2")
    end


    # alternative approach to @eval on using/import?
    # old_stdin = stdin
    # redirect_stdin(devnull)
    # try
    #     using Optim
    # catch e
    #     rethrow(e)
    # finally
    #     redirect_stdin(old_stdin)
    # end

    repl = Base.active_repl
    # expr = Meta.parse(str)
    expr = Base.parse_input_line(str)
    backend = repl.backendref

    REPL.prepare_next(repl)
    printstyled("\nagent> ", color=:red, bold=:true)
    print(str, "\n")

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
    # reshow the stuff which was printed to stdout/stderr before
    print(captured_content)

    disp = IOBufferDisplay()

    # generate printout, err goes to disp.err, val goes to "specialdisplay" disp
    if VERSION >= v"1.11"
        REPL.print_response(disp.io, response, backend, !REPL.ends_with_semicolon(str), false, disp)
    else
        REPL.print_response(disp.io, response, !REPL.ends_with_semicolon(str), false, disp)
    end

    # generate the printout again for the "normal" repl
    REPL.print_response(repl, response, !REPL.ends_with_semicolon(str), repl.hascolor)

    REPL.prepare_next(repl)
    REPL.LineEdit.refresh_line(repl.mistate)

    # Combine captured output with display output
    display_content = String(take!(disp.io))

    return captured_content*display_content
end

SERVER = Ref{Union{Nothing, MCPServer}}(nothing)

"""
    get_environment_info()

Gather basic environment information including current directory and active project.

# Returns
- `Dict{Symbol,Any}`: Dictionary with keys :cwd, :active_project, :project_data.
"""
function get_environment_info()
    if !isdefined(Main, :Pkg)
        @warn "Main.Pkg is not defined"
        return Dict{Symbol,Any}(
            :cwd => pwd(),
            :active_project => nothing,
            :project_data => nothing
        )
    end
    Pkg = Main.Pkg

    active_proj = Base.active_project()
    project_data = nothing
    if active_proj !== nothing && isfile(active_proj)
        try
            project_data = Pkg.TOML.parsefile(active_proj)
        catch
            # TOML parse failed, leave project_data as nothing
        end
    end

    return Dict{Symbol,Any}(
        :cwd => pwd(),
        :active_project => active_proj,
        :project_data => project_data
    )
end

"""
    get_package_info(active_proj::Union{String,Nothing}, project_data::Union{Dict,Nothing})

Gather package information including dependencies, development packages, and current environment package.

# Returns
- `Dict{Symbol,Any}`: Dictionary with keys :current_env_package, :dev_deps, :regular_deps, :dev_packages, :has_revise.
"""
function get_package_info(active_proj::Union{String,Nothing}, project_data::Union{Dict,Nothing})
    if !isdefined(Main, :Pkg)
        @warn "Main.Pkg is not defined"
        return Dict{Symbol,Any}(
            :current_env_package => nothing,
            :dev_deps => [],
            :regular_deps => [],
            :dev_packages => Dict{String, String}(),
            :has_revise => false
        )
    end
    Pkg = Main.Pkg

    current_env_package = nothing
    dev_deps = Any[]
    regular_deps = Any[]
    dev_packages = Dict{String, String}()

    try
        redirect_stdout(devnull) do
            Pkg.status(; mode = Pkg.PKGMODE_MANIFEST)
        end

        deps = Pkg.dependencies()

        for (uuid, pkg_info) in deps
            if pkg_info.is_direct_dep && pkg_info.is_tracking_path
                dev_packages[pkg_info.name] = pkg_info.source
            end
        end

        if project_data !== nothing && haskey(project_data, "uuid")
            pkg_name = get(project_data, "name", basename(dirname(active_proj)))
            pkg_dir = dirname(active_proj)
            dev_packages[pkg_name] = pkg_dir

            pkg_version = get(project_data, "version", "dev")
            pkg_uuid = project_data["uuid"]
            current_env_package = (name = pkg_name, version = pkg_version, uuid = pkg_uuid, path = pkg_dir)
        end

        for (uuid, pkg_info) in deps
            if pkg_info.is_direct_dep
                if haskey(dev_packages, pkg_info.name)
                    push!(dev_deps, pkg_info)
                else
                    push!(regular_deps, pkg_info)
                end
            end
        end
    catch e
        @warn "Error getting package status" exception=e
    end

    has_revise = isdefined(Main, :Revise)

    return Dict{Symbol,Any}(
        :current_env_package => current_env_package,
        :dev_deps => dev_deps,
        :regular_deps => regular_deps,
        :dev_packages => dev_packages,
        :has_revise => has_revise
    )
end

"""
    format_status_report(env_info::Dict{Symbol,Any}, pkg_info::Dict{Symbol,Any}) -> Nothing

Format and print the status report from gathered environment and package information.
"""
function format_status_report(env_info::Dict{Symbol,Any}, pkg_info::Dict{Symbol,Any})
    println("🔍 Julia Environment Investigation")
    println("=" ^ 50)
    println()

    println("📁 Current Directory:")
    println("   $(env_info[:cwd])")
    println()

    println("📦 Active Project:")
    active_proj = env_info[:active_project]
    project_data = env_info[:project_data]
    if active_proj !== nothing
        println("   Path: $active_proj")
        if project_data !== nothing
            if haskey(project_data, "name")
                println("   Name: $(project_data["name"])")
            else
                println("   Name: $(basename(dirname(active_proj)))")
            end
            if haskey(project_data, "version")
                println("   Version: $(project_data["version"])")
            end
        else
            println("   Error reading project info")
        end
    else
        println("   No active project")
    end
    println()

    println("📚 Package Environment:")
    current_env_package = pkg_info[:current_env_package]
    dev_deps = pkg_info[:dev_deps]
    regular_deps = pkg_info[:regular_deps]
    dev_packages = pkg_info[:dev_packages]

    has_dev_packages = !isempty(dev_deps) || current_env_package !== nothing
    if has_dev_packages
        println("   🔧 Development packages (tracked by Revise):")

        if current_env_package !== nothing
            println("      $(current_env_package.name) v$(current_env_package.version) [CURRENT ENV] => $(current_env_package.path)")
            try
                pkg_dir = pkgdir(current_env_package.name)
                if pkg_dir !== nothing && pkg_dir != current_env_package.path
                    println("         pkgdir(): $pkg_dir")
                end
            catch
                # pkgdir might fail, ignore
            end
        end

        for pkg_info in dev_deps
            if current_env_package !== nothing && pkg_info.name == current_env_package.name
                continue
            end
            println("      $(pkg_info.name) v$(pkg_info.version) => $(dev_packages[pkg_info.name])")
            try
                pkg_dir = pkgdir(pkg_info.name)
                if pkg_dir !== nothing && pkg_dir != dev_packages[pkg_info.name]
                    println("         pkgdir(): $pkg_dir")
                end
            catch
                # pkgdir might fail, ignore
            end
        end
        println()
    end

    if !isempty(regular_deps)
        println("   📦 Other packages in environment:")
        for pkg_info in regular_deps
            println("      $(pkg_info.name) v$(pkg_info.version)")
        end
    end

    if isempty(dev_deps) && isempty(regular_deps) && current_env_package === nothing
        println("   No packages in environment")
    end

    println()
    println("🔄 Revise.jl Status:")
    if pkg_info[:has_revise]
        println("   ✅ Revise.jl is loaded and active")
        println("   📝 Development packages will auto-reload on changes")
    else
        println("   ⚠️  Revise.jl is not loaded")
    end

    return nothing
end

"""
    repl_status_report() -> Nothing

Generate and print a comprehensive Julia environment status report.
"""
function repl_status_report()
    try
        env_info = get_environment_info()
        pkg_info = get_package_info(env_info[:active_project], env_info[:project_data])
        format_status_report(env_info, pkg_info)
        return nothing
    catch e
        println("Error generating environment report: $e")
        return nothing
    end
end

function start!(; verbose::Bool = true)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    usage_instructions_tool = MCPTool(
        "usage_instructions",
        "Get detailed instructions for proper Julia REPL usage, best practices, and workflow guidelines for AI agents.",
        Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => []
        ),
        args -> begin
            try
                workflow_path = joinpath(dirname(dirname(@__FILE__)), "prompts", "julia_repl_workflow.md")
                if isfile(workflow_path)
                    return read(workflow_path, String)
                else
                    return "Error: julia_repl_workflow.md not found at $workflow_path"
                end
            catch e
                return "Error reading usage instructions: $e"
            end
        end
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
        MCPRepl.text_parameter("expression", "Julia expression to evaluate (e.g., '2 + 3 * 4' or `import Pkg; Pkg.status()`"),
        args -> begin
            try
                execute_repllike(get(args, "expression", ""))
            catch e
                println("Error during execute_repllike", e)
                "Apparently there was an **internal** error to the MCP server: $e"
            end
        end
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
                result = run(pipeline(`sed -i 's/[[:space:]]*$//' $file_path`, stderr=devnull))

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
        Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => []
        ),
        args -> begin
            try
                execute_repllike("MCPRepl.repl_status_report()")
            catch e
                "Error investigating environment: $e"
            end
        end
    )

    # Create and start server
    SERVER[] = start_mcp_server([usage_instructions_tool, repl_tool, whitespace_tool, investigate_tool], 3000; verbose=verbose)

    if isdefined(Base, :active_repl)
        set_prefix!(Base.active_repl)
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
    only(filter(repl.interface.modes) do mode
        mode isa REPL.Prompt && mode.prompt isa Function && contains(mode.prompt(), "julia>")
    end)
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

end #module
