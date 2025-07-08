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

function check_mcp_status()
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

function setup()
    status = check_mcp_status()

    if status == :claude_not_found
        println("⚠️  Claude Code not found in PATH")
        println("   Please install Claude Code first: https://docs.anthropic.com/en/docs/claude-code")
        return
    end

    # Show current status
    println("🔧 MCPRepl Setup")
    println()
    if status == :configured_http
        println("📊 Current status: ✅ MCP server configured (HTTP transport)")
    elseif status == :configured_script
        println("📊 Current status: ✅ MCP server configured (script transport)")
    elseif status == :configured_unknown
        println("📊 Current status: ✅ MCP server configured (unknown transport)")
    else
        println("📊 Current status: ❌ MCP server not configured")
    end
    println()

    # Show options
    println("Available actions:")
    if status in [:configured_http, :configured_script, :configured_unknown]
        println("   [1] Remove current MCP configuration")
        println("   [2] Add/Replace with HTTP transport")
        println("   [3] Add/Replace with script transport")
    else
        println("   [1] Add HTTP transport")
        println("   [2] Add script transport")
    end
    println()
    print("   Enter choice: ")

    choice = readline()

    if status in [:configured_http, :configured_script, :configured_unknown]
        if choice == "1"
            println("\n   Removing MCP configuration...")
            try
                run(`claude mcp remove julia-repl`)
                println("   ✅ Successfully removed MCP configuration")
            catch e
                println("   ❌ Failed to remove MCP configuration: $e")
            end
        elseif choice == "2"
            println("\n   Adding/Replacing with HTTP transport...")
            try
                run(`claude mcp add julia-repl http://localhost:3000 --transport http`)
                println("   ✅ Successfully configured HTTP transport")
            catch e
                println("   ❌ Failed to configure HTTP transport: $e")
            end
        elseif choice == "3"
            println("\n   Adding/Replacing with script transport...")
            try
                run(`claude mcp add julia-repl $(pkgdir(MCPRepl))/mcp-julia-adapter`)
                println("   ✅ Successfully configured script transport")
            catch e
                println("   ❌ Failed to configure script transport: $e")
            end
        else
            println("\n   Invalid choice. Please run MCPRepl.setup() again.")
            return
        end
    else
        if choice == "1"
            println("\n   Adding HTTP transport...")
            try
                run(`claude mcp add julia-repl http://localhost:3000 --transport http`)
                println("   ✅ Successfully configured HTTP transport")
            catch e
                println("   ❌ Failed to configure HTTP transport: $e")
            end
        elseif choice == "2"
            println("\n   Adding script transport...")
            try
                run(`claude mcp add julia-repl $(pkgdir(MCPRepl))/mcp-julia-adapter`)
                println("   ✅ Successfully configured script transport")
            catch e
                println("   ❌ Failed to configure script transport: $e")
            end
        else
            println("\n   Invalid choice. Please run MCPRepl.setup() again.")
            return
        end
    end

    println("   💡 HTTP for direct connection, script for agent compatibility")
end

function start!(; verbose::Bool = true)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    repl_tool = MCPTool(
        "exec_repl",
        """
        Execute Julia code in a shared, persistent REPL session to avoid startup latency.

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

    # Create and start server
    SERVER[] = start_mcp_server([repl_tool], 3000; verbose=verbose)

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
