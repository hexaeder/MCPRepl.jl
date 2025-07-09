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
Base.display(d::IOBufferDisplay, x) = show(d.io, x)
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
            r = REPL.eval_with_backend(expr, backend)
            close(Base.pipe_writer(captured_output))
            r
        end
    end
    captured_content = read(captured_output, String)
    # reshow the stuff which was printed to stdout/stderr before
    print(captured_content)

    disp = IOBufferDisplay()

    # generate printout, err goest to disp.err, val goes to "specialdisplay" disp
    REPL.print_response(disp.io, response, backend, !REPL.ends_with_semicolon(str), false, disp)

    # generate the printout again for the "normal" repl
    REPL.print_response(repl, response, !REPL.ends_with_semicolon(str), repl.hascolor)

    REPL.prepare_next(repl)
    REPL.LineEdit.refresh_line(repl.mistate)

    # Combine captured output with display output
    display_content = String(take!(disp.io))

    return captured_content*display_content
end

SERVER = Ref{Union{Nothing, MCPServer}}(nothing)


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

        You may use this REPL to
        - execute julia code
        - execute test sets
        - get julia function documentation (i.e. send @doc functionname)

        IMPORTANT: This REPL is shared with the user in real-time. Be respectful:
        (1) Don't clutter workspace with unnecessary variables,
        (2) Ask before long-running commands (>5 seconds),
        (3) Use temporary variables when possible (e.g., let blocks),
        (4) Clean up variables the user doesn't need.
        (5) The REPL uses Revise, so after changing julia functions in the src,
            the changes should be picked up when you execute the same code again.
            This does not work on redefining structs or constants! You need to ask the user
            to restart the REPL in that case!
        (6) Never use `Pkg.activate` to change the current environment! Expect that you are in a sensible environment for your tasks.
            Always prompt user if you need more packages. If you need to use a third-party `activate` function,
            add '# overwrite no-activate-rule' at the end of your command to bypass this check.
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

    # Create and start server
    SERVER[] = start_mcp_server([usage_instructions_tool, repl_tool, whitespace_tool], 3000; verbose=verbose)

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
        unset_prefix!(Base.active_repl) # Reset the prompt prefix
    else
        println("No server running to stop.")
    end
end

end #module
