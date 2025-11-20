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

                quiz_path = joinpath(
                    dirname(dirname(@__FILE__)),
                    "prompts",
                    filename,
                )

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

    manage_repl_tool = @mcp_tool(
        :manage_repl,
        """Manage the Julia REPL (restart or shutdown).

**Commands:**
- `restart`: Restart the Julia REPL (auto-restart will continue)
- `shutdown`: Shutdown the Julia REPL and disable auto-restart

**Restart Behavior:**
After restart, the REPL will automatically restart again unless a shutdown was requested.
Returns immediately, then server restarts (wait 5s, retry every 2s).

**Shutdown Behavior:**
Creates a flag file that prevents auto-restart, then triggers a clean shutdown.
The REPL will exit and stay stopped until manually restarted.""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "command" => Dict(
                    "type" => "string",
                    "enum" => ["restart", "shutdown"],
                    "description" => "Command to execute: 'restart' or 'shutdown'",
                ),
            ),
            "required" => ["command"],
        ),
        (args, stream_channel = nothing) -> begin
            try
                command = get(args, "command", "")
                
                if isempty(command)
                    return "Error: command parameter is required (must be 'restart' or 'shutdown')"
                end
                
                # Get the current server port (before restart)
                server_port = SERVER[] !== nothing ? SERVER[].port : 3000
                
                if command == "shutdown" || command == "restart"
                    if command == "shutdown"
                        # Create the no-restart flag file
                        mcprepl_dir = joinpath(pwd(), ".mcprepl")
                        flag_file = joinpath(mcprepl_dir, ".no-restart")
                        
                        # Ensure .mcprepl directory exists
                        if !isdir(mcprepl_dir)
                            mkdir(mcprepl_dir)
                        end
                        
                        # Create flag file
                        touch(flag_file)
                    end
                    # Get the PID of the current process
                    pid = getpid()

                    @async begin
                        # Small delay to allow response to be sent back
                        sleep(0.5)
                        exit()
                    end
                    if command == "shutdown"
                        return """✓ Julia REPL shutdown initiated.

    🛑 Auto-restart has been disabled.

    **What happens next:**
    1. The Julia REPL will exit cleanly
    2. The repl script will detect the shutdown flag and exit
    3. The REPL will NOT automatically restart

    **To restart manually:**
    Run the `./repl` script again from your terminal.
    Auto-restart will be re-enabled on the next start."""
                    else                    
                        return """✓ Julia REPL restart initiated on port $server_port.

    ⏳ The MCP server will be temporarily offline during restart.

    **AI Agent Instructions:**
    1. Wait 5 seconds before making any requests
    2. Then retry every 2 seconds until connection is reestablished
    3. Typical restart time: 5-10 seconds (may be longer if packages need recompilation)

    The server will automatically restart and be ready when the Julia REPL finishes loading."""
                    end
                else
                    return "Error: Invalid command '$command'. Must be 'restart' or 'shutdown'"
                end
            catch e
                return "Error managing REPL: $e"
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
                MCPRepl.repl_status_report()
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
                    # Construct code with package name - interpolate at this level
                    pkg_symbol = Symbol(pkg_name)
                    code = """
                    using Aqua
                    @eval using $pkg_symbol
                    println("Running Aqua tests for package: $pkg_name")
                    Aqua.test_all($pkg_symbol)
                    println("✅ All Aqua tests passed for $pkg_name")
                    """
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

    run_tests_tool = @mcp_tool(
        :run_tests,
        """Run tests and optionally generate coverage reports.

This tool provides comprehensive test execution with optional coverage analysis.

# Parameters

- `pattern`: Optional test pattern to filter which tests to run (ReTest pattern syntax)
- `coverage`: Boolean flag to enable coverage collection (default: false)
- `verbose`: Verbosity level for test output (default: 1.0)

# Examples

Run all tests:
```julia
{"pattern": ""}
```

Run specific tests matching a pattern:
```julia
{"pattern": "security", "verbose": true}
```

Run tests with coverage:
```julia
{"coverage": true}
```

# Returns

Test results summary including:
- Number of tests passed/failed
- Coverage percentage (if coverage=true)
- Detailed failure information (if any)
""",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "pattern" => Dict(
                    "type" => "string",
                    "description" =>
                        "Optional test regex to filter tests (ReTest pattern syntax, e.g., 'security' or 'generate'). Leave empty to run all tests.",
                ),
                "coverage" => Dict(
                    "type" => "boolean",
                    "description" =>
                        "Enable coverage collection and reporting (default: false)",
                    "default" => false,
                ),
                "verbose" => Dict(
                    "type" => "integer",
                    "description" => "Enable verbose test output (default: false)",
                    "default" => 1,
                ),
            ),
            "required" => [],
        ),
        function (args)
            pattern = get(args, "pattern", ".*")
            coverage_enabled = get(args, "coverage", false)
            verbose = parse(Int, get(args, "verbose", "1"))

            out_buf = IOBuffer()
            try
                if coverage_enabled
                    println(out_buf, "🧪 Running tests with coverage collection...\n")
                    # Clear any previous coverage data
                    Coverage.clean_folder("src")
                    Coverage.clean_folder("test")
                else
                    println(out_buf, "🧪 Running tests...\n")
                end
                    
                hasReTest = "ReTest" in [p.name for p in values(Pkg.dependencies())]

                try
                    if hasReTest
                        ReTest.hijack(Pkg.project().name)
                        output = retest(Regex(pattern); verbose=verbose)
                    else
                        output = Pkg.test(coverage=coverage_enabled)
                    end
                    test_ran = true
                    print(out_buf, output)
                catch e
                    print(out_buf, "Error running tests: $e")
                end

                if coverage_enabled
                    println(out_buf, "\n📊 Processing coverage data...\n")

                    coverage = process_folder("src")
                    covered_lines, total_lines = get_summary(coverage)
                    coverage_pct = total_lines > 0 ? round(100 * covered_lines / total_lines, digits=2) : 0.0
                    
                    println(out_buf, "Coverage Summary:")
                    println(out_buf, "  Lines covered: \$covered_lines / \$total_lines")
                    println(out_buf, "  Coverage: \$(coverage_pct)%")

                    # Generate LCOV report
                    LCOV.writefile("coverage-lcov.info", coverage)
                    println(out_buf, "\n✅ Coverage report written to: coverage-lcov.info")
                end
                return String(take!(out_buf))
            catch e
                return "Error running tests: $e\n$(sprint(showerror, e, catch_backtrace()))"
            end
        end
    )