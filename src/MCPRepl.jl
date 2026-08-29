module MCPRepl

using REPL
using HTTP
using JSON
using Sockets

include("MCPServer.jl")
include("setup.jl")

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

# Which REPL.print_response signature this Julia has: newer ones take the backend
# as a third positional argument. Probed by method, not by VERSION, because the
# change was backported into the 1.11 patch series.
const PRINT_RESPONSE_TAKES_BACKEND =
    hasmethod(REPL.print_response, Tuple{IO,Any,REPL.REPLBackendRef,Bool,Bool})

function execute_repllike(str)
    # Hard block: Pkg.activate — no override allowed
    if contains(str, "Pkg.activate(")
        return """
            ERROR: Pkg.activate() is not allowed. You must stay in the current environment.
            You may use Pkg.status() to inspect available packages.
            If you think the currect environment is not sufficient, ask the user to change it!
        """
    end
    # Hard block: Pkg.add — no override allowed
    if contains(str, "Pkg.add(")
        return """
            ERROR: Pkg.add() is not allowed. You must assume all necessary packages are already installed.
            If you need another package, ask the user to install it!
        """
    end
    # Soft block: bare activate( — catches `using Pkg; activate(...)` style
    if contains(str, "activate(") && !contains(str, r"#\s*this is not Pkg\.activate")
        return """
            ERROR: Calling activate() is not allowed (this may be Pkg.activate in disguise).
            You must stay in the current environment.
            If this 'activate' is genuinely a third-party function unrelated to Pkg,
            annotate the line with:
              # this is not Pkg.activate
        """
    end
    # Soft block: bare add( — catches `using Pkg; add(...)` style
    if contains(str, r"\badd\(") && !contains(str, r"#\s*this is not Pkg\.add")
        return """
            ERROR: Calling add() is not allowed (this may be Pkg.add in disguise).
            You must assume all necessary packages are already installed.
            If this 'add' is genuinely a third-party function unrelated to Pkg,
            annotate the line with:
              # this is not Pkg.add
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
    # Note: `using Foo` for a package missing from the env used to hang on a
    # stdin install-prompt. That prompt is injected by the REPL backend's
    # `check_for_missing_packages_and_run_hooks` -> `install_packages_hooks`
    # (REPL.jl). We neutralize that hook in `start!` (see
    # `suppress_install_prompts!`), so a plain `using Foo` now surfaces Base's
    # clean `ArgumentError` instead of blocking. No source rewriting needed.

    repl = Base.active_repl
    # expr = Meta.parse(str)
    expr = Base.parse_input_line(str)
    backend = repl.backendref

    REPL.prepare_next(repl)
    printstyled("\nagent> ", color=:red, bold=:true)
    print(str, "\n")

    # Capture stdout/stderr during execution while *streaming* it live to the
    # user's real terminal, so long-running code shows progress instead of only
    # flushing at the end. We pre-link the pipe with async support (so the
    # reader end is non-blocking) and tee it: every chunk goes both to the
    # original terminal and to a buffer we return to the agent.
    orig_out = stdout
    captured_output = Pipe()
    Base.link_pipe!(captured_output; reader_supports_async = true, writer_supports_async = true)
    buf = IOBuffer()
    reader = @async begin
        try
            while !eof(captured_output)
                data = readavailable(captured_output)
                write(orig_out, data)
                flush(orig_out)
                write(buf, data)
            end
        catch e
            @warn "MCPRepl: output tee reader failed" exception = e
        end
    end

    response = redirect_stdout(captured_output) do
        redirect_stderr(captured_output) do
            # eval_with_backend was renamed to eval_on_backend. The rename landed
            # in a 1.11 patch release, so ask REPL what it has rather than
            # comparing version numbers.
            if isdefined(REPL, :eval_on_backend)
                REPL.eval_on_backend(expr, backend)
            else
                REPL.eval_with_backend(expr, backend)
            end
        end
    end
    # Closing the writer signals EOF to the tee reader; wait for it to drain.
    close(Base.pipe_writer(captured_output))
    wait(reader)
    captured_content = String(take!(buf))

    disp = IOBufferDisplay()

    # generate printout, err goes to disp.err, val goes to "specialdisplay" disp
    # The `backend` positional arg was added to print_response at some point during
    # the 1.11 series; before that the signature is
    # (io, response, show_value, have_color, specialdisplay). Detect it by method.
    if PRINT_RESPONSE_TAKES_BACKEND
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

# Large-output handling ------------------------------------------------------
#
# REPL output (especially long stacktraces) is returned verbatim to the agent
# and counts directly against its context window. To bound token usage we keep
# a generous head (which holds the `ERROR:` line and the top of the stacktrace)
# plus a small tail, elide the middle, and spill the *full* output to a file the
# agent can Read/Grep on demand.
const MAX_OUTPUT_CHARS = 12_000
const HEAD_CHARS = 6_000
const TAIL_CHARS = 2_000

function maybe_truncate_output(text::AbstractString)
    total_chars = length(text)
    total_chars <= MAX_OUTPUT_CHARS && return text

    total_lines = count(==('\n'), text) + 1
    elided_chars = total_chars - HEAD_CHARS - TAIL_CHARS

    # Persist the full output outside the project tree so the agent can inspect
    # the elided part if it needs to. cleanup=false keeps the file after exit.
    dir = joinpath(tempdir(), "mcprepl")
    mkpath(dir)
    path = tempname(dir; cleanup = false) * ".txt"
    try
        write(path, text)
    catch e
        # If we can't spill, fall back to returning the untruncated text rather
        # than losing information.
        @warn "MCPRepl: failed to write full output to file" exception = e
        return text
    end

    marker = string(
        "\n\n",
        "…… [output truncated: $elided_chars of $total_chars chars / $total_lines lines elided] ……\n",
        "Full output written to: $path\n",
        "Read or Grep that file if you need the elided middle section.\n\n",
    )

    return first(text, HEAD_CHARS) * marker * last(text, TAIL_CHARS)
end

# Missing-package prompt suppression -----------------------------------------
#
# When `using Foo` names a package not in the environment, the REPL backend's
# `check_for_missing_packages_and_run_hooks` (REPL.jl) invokes Pkg's
# `install_packages_hooks`, which prompts on stdin ("install? [y/n]"). In a
# shared, agent-driven REPL stdin isn't routed, so that prompt hangs forever.
#
# We replace the hook list with a single no-op hook that returns `true`
# ("handled"), so no prompt is shown; evaluation then proceeds and Base throws
# its normal, informative `ArgumentError` ("Package Foo not found ... Pkg.add").
# This is global for the session, which is the right default for this server:
# no contested stdin prompts. The user can still `Pkg.add` explicitly.
function suppress_install_prompts!()
    empty!(REPL.install_packages_hooks)
    push!(REPL.install_packages_hooks, Returns(true))
    return nothing
end

# Multiplexing across several REPLs ------------------------------------------
#
# Multiple Julia REPLs can each run their own MCPRepl server. There is no central
# daemon: each REPL binds its own port and drops a small JSON file into a shared
# registry directory. The per-project stdio adapter (`mcp-julia-adapter`) reads
# that directory to discover REPLs and route each call to the right one. See the
# adapter for the routing logic.

# Short, human-recognizable handles so a REPL can be named in an adapter listing
# ("otter — /path/to/foo") and passed as `repl=<word>`. Derived deterministically
# from the project directory so a REPL keeps its word across restarts.
const WORDLIST = [
    "otter", "badger", "heron", "marten", "lynx", "ibis", "raven", "newt",
    "koi", "vole", "finch", "shrew", "egret", "stoat", "quail", "tapir",
    "gecko", "moth", "wren", "cobra", "civet", "dingo", "eagle", "ferret",
    "gopher", "hare", "iguana", "jackal", "krill", "lemur", "mink", "numbat",
    "osprey", "puma", "quokka", "robin", "seal", "toad", "urchin", "viper",
    "walrus", "yak", "zebra", "bison", "crane", "dove", "elk", "fox",
]

# Directory that holds one `<pid>.json` file per running REPL. Under the home
# directory so project trees stay clean. Override with MCPREPL_REGISTRY_DIR
# (the adapter honors the same variable) to relocate or isolate the registry.
registry_dir() = get(ENV, "MCPREPL_REGISTRY_DIR", joinpath(homedir(), ".mcprepl", "registry"))

# realpath that never throws (falls back to the abspath) so registration can't
# fail on an unusual project path.
_realpath_safe(p) = try
    realpath(p)
catch
    abspath(p)
end

# Nearest enclosing git project of `startdir`, searching upward but stopping
# *before* the home directory (a `.git` at or above ~ is ignored). Returns "" if
# none is found. The adapter uses this so any REPL inside the same git project as
# the agent's working dir is treated as the ideal routing target — even a sibling
# subfolder. See the adapter's matching logic.
function _git_root(startdir::AbstractString)
    dir = _realpath_safe(startdir)
    home = _realpath_safe(homedir())
    while true
        dir == home && return ""            # reached ~ -> stop, no project
        ispath(joinpath(dir, ".git")) && return dir
        parent = dirname(dir)
        parent == dir && return ""           # filesystem root
        dir = parent
    end
end

# True if a process with `pid` currently exists. Uses kill(pid, 0), which sends
# no signal — it just asks the kernel whether the pid is signalable. Cheap (one
# syscall, no spawn). A live process owned by another user returns EPERM, which
# still means "alive"; only ESRCH ("no such process") counts as dead.
function _pid_alive(pid::Integer)
    pid > 0 || return false
    ret = ccall(:kill, Cint, (Cint, Cint), pid, 0)
    ret == 0 && return true
    return Libc.errno() == Libc.EPERM
end

# Delete registry files whose owning REPL process is gone. Runs once at the top
# of `start!`, before name-picking, so `_claimed_words` reads an already-pruned
# directory and can stay a plain read (no per-word liveness checks). Only files
# that parse cleanly AND name a dead pid are removed — a partial/unparseable file
# (a REPL mid-registration) is left alone, and a starting REPL's own file is
# never at risk since its pid is alive by definition. The rm is best-effort: two
# REPLs starting at once may race to unlink the same corpse.
function reap_stale_registry!()
    dir = registry_dir()
    isdir(dir) || return nothing
    for f in readdir(dir; join = true)
        endswith(f, ".json") || continue
        pid = try
            get(JSON.parse(read(f, String)), "pid", nothing)
        catch
            continue  # unparseable/partial — leave it (may be mid-write)
        end
        pid isa Integer || continue
        _pid_alive(pid) && continue
        try
            rm(f; force = true)
        catch
            # Best-effort: another starting REPL may have unlinked it first.
        end
    end
    return nothing
end

# Words currently claimed by registry files. A plain read: `reap_stale_registry!`
# is expected to have already pruned dead REPLs, so every word here belongs to a
# live REPL. Best-effort — unreadable/partial files are skipped.
function _claimed_words()
    dir = registry_dir()
    words = String[]
    isdir(dir) || return words
    for f in readdir(dir; join = true)
        endswith(f, ".json") || continue
        try
            data = JSON.parse(read(f, String))
            w = get(data, "word", "")
            isempty(w) || push!(words, w)
        catch
            # Ignore unreadable/partial files.
        end
    end
    return words
end

# Deterministic word for a project dir, advancing past any word already taken.
# With the registry pruned of dead REPLs, "taken" means a live REPL holds it, so
# exhausting the list is a genuine "48 live REPLs" condition — a loud error beats
# silently handing out a duplicate word-id.
function wordid_for(project_dir::AbstractString, taken = _claimed_words())
    n = length(WORDLIST)
    base = 1 + (hash(_realpath_safe(project_dir)) % n)
    for i in 0:(n - 1)
        w = WORDLIST[1 + (base - 1 + i) % n]
        w in taken || return w
    end
    error("All $n REPL word-ids are in use by live REPLs; cannot assign a unique " *
          "word-id. Stop an unused REPL and try again.")
end

# Prefer the historic default port 3000 for the first REPL; if it is already bound
# (another REPL is there), take an OS-assigned ephemeral port instead so a second
# REPL can coexist. Returns the port to bind.
function choose_port(preferred::Int = 3000)
    try
        s = Sockets.listen(Sockets.localhost, preferred)
        close(s)
        return preferred
    catch
        s = Sockets.listen(Sockets.localhost, 0)
        port = Int(Sockets.getsockname(s)[2])
        close(s)
        return port
    end
end

# State for the registry file this REPL owns, so `stop!`/atexit can remove it.
const _REGISTRY_FILE = Ref{Union{Nothing, String}}(nothing)
const _WORD = Ref{Union{Nothing, String}}(nothing)
const _PORT = Ref{Union{Nothing, Int}}(nothing)
const _ATEXIT_INSTALLED = Ref(false)

# Write this REPL's registry file. `word` is precomputed so the startup banner and
# the file agree.
function register_repl!(port::Int, word::AbstractString; private::Bool = false)
    dir = registry_dir()
    mkpath(dir)
    active = Base.active_project()
    project_dir = active === nothing ? pwd() : dirname(active)
    data = Dict(
        "pid" => getpid(),
        "port" => port,
        "host" => "127.0.0.1",
        "word" => word,
        "project_dir" => project_dir,
        "project_name" => basename(project_dir),
        "active_project" => active === nothing ? "" : active,
        "pwd" => pwd(),
        "git_root" => _git_root(pwd()),
        "julia_version" => string(VERSION),
        "started_at" => time(),
        # Private REPLs are agent-spawned and hidden from the adapter's pool; the
        # spawn_token lets the adapter match the record it just launched, and
        # owner_pid (the adapter's pid) lets it reap orphans if that adapter dies.
        "private" => private,
        "spawn_token" => get(ENV, "MCPREPL_SPAWN_TOKEN", ""),
        "owner_pid" => something(tryparse(Int, get(ENV, "MCPREPL_OWNER_PID", "")), 0),
        # The adapter picks the tmux session name (with an informative, project-based
        # label) at spawn and passes it in; recording it lets kill/orphan-reap target
        # the session by its real name instead of re-deriving it from the token.
        "tmux_session" => get(ENV, "MCPREPL_TMUX_SESSION", ""),
    )
    path = joinpath(dir, "$(getpid()).json")
    write(path, JSON.json(data))
    _REGISTRY_FILE[] = path
    _WORD[] = word
    _PORT[] = port
    if !_ATEXIT_INSTALLED[]
        atexit(unregister_repl!)   # best-effort cleanup on normal exit
        _ATEXIT_INSTALLED[] = true
    end
    return nothing
end

function unregister_repl!()
    f = _REGISTRY_FILE[]
    if f !== nothing
        try
            rm(f; force = true)
        catch
            # Best-effort: a stale file is pruned by the adapter via pid-liveness.
        end
        _REGISTRY_FILE[] = nothing
    end
    return nothing
end

SERVER = Ref{Union{Nothing, MCPServer}}(nothing)

function repl_status_report()
    if !isdefined(Main, :Pkg)
        error("Expect Main.Pkg to be defined.")
    end
    Pkg = Main.Pkg

    try
        # Basic environment info
        println("🔍 Julia Environment Investigation")
        println("=" ^ 50)
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
            dev_packages = Dict{String, String}()

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
                        current_env_package = (name = pkg_name, version = pkg_version, uuid = pkg_uuid, path = dirname(active_proj))
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
                    println("      $(current_env_package.name) v$(current_env_package.version) [CURRENT ENV] => $(current_env_package.path)")
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
                    if current_env_package !== nothing && pkg_info.name == current_env_package.name
                        continue
                    end
                    println("      $(pkg_info.name) v$(pkg_info.version) => $(dev_packages[pkg_info.name])")
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

function start!(; verbose::Bool = true, private::Bool = false)
    SERVER[] !== nothing && stop!() # Stop existing server if running

    suppress_install_prompts!() # `using MissingPkg` errors cleanly instead of hanging on a stdin prompt

    # Note: `usage_instructions` is owned by the adapter, not the REPL. The adapter
    # serves it even when no REPL is running (exactly when a bootstrapping agent
    # needs it), so there is no Julia-side copy.

    repl_tool = MCPTool(
        "exec_repl",
        """
        Execute Julia code in a shared, persistent REPL session to avoid startup latency.

        **PREREQUISITE**: Before using this tool, you MUST first call the `usage_instructions` tool to understand proper Julia REPL workflow, best practices, and etiquette for shared REPL usage.

        Prefer the REPL for anything iterative or stateful: you skip startup/precompile latency (TTFX) and keep live state across calls. Not every task needs it, though — a self-contained one-shot is fine to run as `julia --project=<path> --startup-file=no somescript.jl` in bash (always pass `--startup-file=no` there so the user's startup.jl doesn't interfere).

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
                expr = get(args, "expression", nothing)
                if !(expr isa AbstractString) || isempty(strip(expr))
                    # No usable code under the declared `expression` key.
                    # Historically we silently evaluated "" here, which printed an
                    # empty `agent>` and returned no output — indistinguishable
                    # from a lost message. Instead, tell the caller exactly what
                    # was expected and what it actually sent, so it can retry with
                    # the right argument.
                    got = isempty(args) ? "no arguments were provided" :
                          "the arguments provided were: " *
                          join(sort!(collect(keys(args))), ", ")
                    "ERROR: exec_repl requires the Julia code in an \"expression\" " *
                    "argument, but $got. Retry with e.g. {\"expression\": \"1 + 1\"}."
                else
                    maybe_truncate_output(execute_repllike(expr))
                end
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
                maybe_truncate_output(execute_repllike("MCPRepl.repl_status_report()"))
            catch e
                "Error investigating environment: $e"
            end
        end
    )

    # Pick a port: keep the historic 3000 when free, else an ephemeral port so a
    # second REPL can coexist. Assign a stable word-id for the adapter's picker.
    port = choose_port(3000)
    active = Base.active_project()
    project_dir = active === nothing ? pwd() : dirname(active)
    # Prune registry files left by dead REPLs before name-picking, so a directory
    # full of corpses can't saturate the wordlist and force duplicate word-ids.
    reap_stale_registry!()
    word = wordid_for(project_dir)

    # Create and start server
    SERVER[] = start_mcp_server([repl_tool, whitespace_tool, investigate_tool], port; verbose=verbose, word=word)

    # Advertise this REPL to the shared registry so the adapter can route to it.
    register_repl!(port, word; private = private)

    if isdefined(Base, :active_repl)
        set_prefix!(Base.active_repl)
        install_interrupt_keybinding!(Base.active_repl)
    else
        atreplinit(set_prefix!)
        atreplinit(install_interrupt_keybinding!)
    end
    nothing
end

function set_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, "✻ julia> ")
    return nothing
end

function unset_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
    return nothing
end

function get_mainmode(repl)
    if isdefined(REPL.LineEdit, :find_mode) && hasmethod(REPL.LineEdit.find_mode, Tuple{Any,Symbol})
        mode = REPL.LineEdit.find_mode(repl.interface.modes, :julia)
        !isnothing(mode) && return mode
    end

    modes = filter(repl.interface.modes) do mode
        mode isa REPL.LineEdit.Prompt && mode.prompt isa Function && contains(mode.prompt(), "julia>")
    end

    if isempty(modes)
        error("Could not find Julia REPL main mode")
    end

    return first(modes)
end

# Ctrl-C interrupt for agent-launched work -----------------------------------
#
# The agent's code runs on the REPL backend (root) task. When *you* run code,
# the terminal is in cooked mode and Ctrl-C is a real SIGINT delivered to that
# task — so it interrupts. But while the *agent* runs code you are sitting at
# the live prompt (raw mode), so Ctrl-C is read as a keystroke whose default
# binding only clears the input line; it never reaches the backend.
#
# We wrap the `^C` (0x03) keybinding so that, when the backend is mid-eval
# (`in_eval`), it schedules an InterruptException onto the backend task —
# exactly what a real SIGINT would do. `eval_user_input` turns that into an
# error response and the backend loop keeps running, so your REPL survives.
# When the backend is idle, the original clear-the-line behavior is preserved.
#
# No timer, no time limit: a legitimately long task runs untouched until you
# decide to stop it.
const _ORIG_CTRLC = Base.IdDict{Any,Function}()

# Schedule an InterruptException onto the REPL backend task iff it is mid-eval —
# exactly what a real SIGINT does. Returns true if an interrupt was scheduled.
# Shared by the Ctrl-C keybinding (local user) and the HTTP `interrupt` method
# (remote cancellation via the adapter): both must behave identically, and both
# run on a task *other* than the backend, so the exception actually lands.
function request_interrupt!()
    # Before 1.12 the binding is only assigned once a REPL actually starts, so a
    # non-interactive process has to be treated as "nothing running".
    be = isdefined(Base, :active_repl_backend) ? Base.active_repl_backend : nothing
    if be !== nothing && getfield(be, :in_eval)
        schedule(getfield(be, :backend_task), InterruptException(); error = true)
        return true
    end
    return false
end

function install_interrupt_keybinding!(repl)
    isdefined(repl, :interface) || return nothing
    for mode in repl.interface.modes
        mode isa REPL.LineEdit.Prompt || continue
        kd = mode.keymap_dict
        (haskey(kd, '\x03') && kd['\x03'] isa Function) || continue
        # Capture the true original once, so repeated start!() calls don't nest wrappers.
        orig = get!(_ORIG_CTRLC, mode, kd['\x03'])
        kd['\x03'] = (s, p, c) -> begin
            request_interrupt!() && return :ignore
            return Base.invokelatest(orig, s, p, c)
        end
    end
    return nothing
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")
        unregister_repl!()   # remove our registry file before dropping the server
        stop_mcp_server(SERVER[])
        SERVER[] = nothing
        _WORD[] = nothing
        _PORT[] = nothing
        if isdefined(Base, :active_repl)
            unset_prefix!(Base.active_repl) # Reset the prompt prefix
        end
    else
        println("No server running to stop.")
    end
end

end #module
