module MCPRepl

using REPL
using HTTP
using JSON3

include("MCPServer.jl")

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

function execute_repllike(str)
    repl = Base.active_repl
    # expr = Meta.parse(str)
    expr = Base.parse_input_line(str)
    backend = repl.backendref

    REPL.prepare_next(repl)
    printstyled("\nagent> $str\n", color=:red, bold=:true)

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

function start!()
    SERVER[] !== nothing && stop!() # Stop existing server if running

    repl_tool = MCPTool(
        "exec_repl",
        """
        Execute Julia code in a shared, persistent REPL session to avoid startup latency.
        IMPORTANT: This REPL is shared with the user in real-time. Be respectful:
        (1) Don't clutter workspace with unnecessary variables,
        (2) Ask before adding packages with 'using',
        (3) Ask before long-running commands (>5 seconds),
        (4) Use temporary variables when possible (e.g., let blocks),
        (5) Clean up variables the user doesn't need.
        (6) The REPL uses Revise, so after changing julia functions in the src,
            the changes should be picket up when you execut the same code again.
            This does not work on redefining structs or constants! You need to ask the user
            to restart the REPL in that case!
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

    # Create and start server
    SERVER[] = start_mcp_server([repl_tool], 3000)
    nothing
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")
        stop_mcp_server(SERVER[])
        SERVER[] = nothing
    else
        println("No server running to stop.")
    end
end

end #module
