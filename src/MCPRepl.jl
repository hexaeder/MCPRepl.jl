module MCPRepl

using REPL

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
    response = REPL.eval_with_backend(expr, backend)

    disp = IOBufferDisplay()

    # generate printout, err goest to disp.err, val goes to "specialdisplay" disp
    REPL.print_response(disp.io, response, backend, !REPL.ends_with_semicolon(str), false, disp)

    # generate the printout again for the "normal" repl
    REPL.print_response(repl, response, !REPL.ends_with_semicolon(str), repl.hascolor)

    REPL.prepare_next(repl)
    REPL.LineEdit.refresh_line(repl.mistate)
    String(take!(disp.io))
end

end # module MCPRepl
