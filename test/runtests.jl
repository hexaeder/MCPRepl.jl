using Test
using MCPRepl
using MCPRepl: MCPTool
using HTTP
using JSON
using Dates
using Sockets

include("setup_codex.jl")

@testset "MCPRepl Tests" begin
    @testset "MCP Server Tests" begin
        # Create test tools
        time_tool = MCPTool(
            "get_time",
            "Get current time in specified format",
            MCPRepl.text_parameter("format", "DateTime format string (e.g., 'yyyy-mm-dd HH:MM:SS')"),
            args -> Dates.format(now(), get(args, "format", "yyyy-mm-dd HH:MM:SS"))
        )

        reverse_tool = MCPTool(
            "reverse_text",
            "Reverse the input text",
            MCPRepl.text_parameter("text", "Text to reverse"),
            args -> reverse(get(args, "text", ""))
        )

        calc_tool = MCPTool(
            "calculate",
            "Evaluate a simple Julia expression",
            MCPRepl.text_parameter("expression", "Julia expression to evaluate (e.g., '2 + 3 * 4')"),
            function(args)
                try
                    expr = Meta.parse(get(args, "expression", "0"))
                    result = eval(expr)
                    string(result)
                catch e
                    "Error: $e"
                end
            end
        )

        tools = [time_tool, reverse_tool, calc_tool]

        @testset "Server Startup and Shutdown" begin
            # Start server on test port
            test_port = 3001
            server = MCPRepl.start_mcp_server(tools, test_port)

            @test server.port == test_port
            @test length(server.tools) == 3
            @test haskey(server.tools, "get_time")
            @test haskey(server.tools, "reverse_text")
            @test haskey(server.tools, "calculate")

            # Give server time to start
            sleep(0.1)

            # Stop server
            MCPRepl.stop_mcp_server(server)

            # Give server time to stop
            sleep(0.1)
        end

        @testset "Empty Body Handling" begin
            # Start server for empty body tests
            test_port = 3002
            server = MCPRepl.start_mcp_server(tools, test_port)

            # Give server time to start
            sleep(0.1)

            try
                # Test GET request with empty body - expect 400 status exception
                response = try
                    HTTP.get("http://localhost:$test_port/")
                catch e
                    if e isa HTTP.Exceptions.StatusError && e.status == 400
                        e.response
                    else
                        rethrow(e)
                    end
                end

                @test response.status == 400
                @test HTTP.header(response, "Content-Type") == "application/json"

                # Parse response JSON
                body = String(response.body)
                json_response = JSON.parse(body)

                @test json_response["jsonrpc"] == "2.0"
                @test json_response["error"]["code"] == -32600
                @test occursin("Invalid Request", json_response["error"]["message"])
                @test occursin("empty body", json_response["error"]["message"])
                @test occursin("empty body", json_response["error"]["message"])

            finally
                # Always stop server
                MCPRepl.stop_mcp_server(server)
                sleep(0.1)
            end
        end

        @testset "Tool Listing" begin
            # Start server for tool listing tests
            test_port = 3003
            server = MCPRepl.start_mcp_server(tools, test_port)

            # Give server time to start
            sleep(0.1)

            try
                # Test tools/list request
                request_body = JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/list"
                ))

                response = HTTP.post(
                    "http://localhost:$test_port/",
                    ["Content-Type" => "application/json"],
                    request_body
                )

                @test response.status == 200

                # Parse response
                body = String(response.body)
                json_response = JSON.parse(body)

                @test json_response["jsonrpc"] == "2.0"
                @test json_response["id"] == 1
                @test haskey(json_response["result"], "tools")
                @test length(json_response["result"]["tools"]) == 3

                # Check tool names
                tool_names = [tool["name"] for tool in json_response["result"]["tools"]]
                @test "get_time" in tool_names
                @test "reverse_text" in tool_names
                @test "calculate" in tool_names

            finally
                # Always stop server
                MCPRepl.stop_mcp_server(server)
                sleep(0.1)
            end
        end

        @testset "Tool Execution" begin
            # Start server for tool execution tests
            test_port = 3004
            server = MCPRepl.start_mcp_server(tools, test_port)

            # Give server time to start
            sleep(0.1)

            try
                # Test reverse_text tool
                request_body = JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "reverse_text",
                        "arguments" => Dict("text" => "hello")
                    )
                ))

                response = HTTP.post(
                    "http://localhost:$test_port/",
                    ["Content-Type" => "application/json"],
                    request_body
                )

                @test response.status == 200

                # Parse response
                body = String(response.body)
                json_response = JSON.parse(body)

                @test json_response["jsonrpc"] == "2.0"
                @test json_response["id"] == 2
                @test haskey(json_response["result"], "content")
                @test length(json_response["result"]["content"]) == 1
                @test json_response["result"]["content"][1]["type"] == "text"
                @test json_response["result"]["content"][1]["text"] == "olleh"

                # Test calculate tool
                request_body = JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "calculate",
                        "arguments" => Dict("expression" => "2 + 3 * 4")
                    )
                ))

                response = HTTP.post(
                    "http://localhost:$test_port/",
                    ["Content-Type" => "application/json"],
                    request_body
                )

                @test response.status == 200

                # Parse response
                body = String(response.body)
                json_response = JSON.parse(body)

                @test json_response["result"]["content"][1]["text"] == "14"

            finally
                # Always stop server
                MCPRepl.stop_mcp_server(server)
                sleep(0.1)
            end
        end

        @testset "Interrupt method" begin
            # With no interactive REPL backend (as in this test process),
            # request_interrupt! is a no-op that reports nothing was running.
            @test MCPRepl.request_interrupt!() == false

            test_port = 3005
            server = MCPRepl.start_mcp_server(tools, test_port)
            sleep(0.1)
            try
                request_body = JSON.json(Dict(
                    "jsonrpc" => "2.0",
                    "id" => 7,
                    "method" => "interrupt"
                ))

                response = HTTP.post(
                    "http://localhost:$test_port/",
                    ["Content-Type" => "application/json"],
                    request_body
                )

                @test response.status == 200
                json_response = JSON.parse(String(response.body))
                @test json_response["id"] == 7
                # No backend eval in flight -> interrupted == false, but the
                # method is handled (not a "method not found" error).
                @test haskey(json_response, "result")
                @test json_response["result"]["interrupted"] == false

            finally
                MCPRepl.stop_mcp_server(server)
                sleep(0.1)
            end
        end
    end

    @testset "Large Output Truncation" begin
        # Small output passes through untouched
        small = "just a little output\n"
        @test MCPRepl.maybe_truncate_output(small) === small

        # Output at the threshold is not truncated
        at_limit = repeat("x", MCPRepl.MAX_OUTPUT_CHARS)
        @test MCPRepl.maybe_truncate_output(at_limit) == at_limit

        # Oversized output is truncated to head + marker + tail, and shrinks
        big = "HEAD-MARKER\n" * repeat("y", MCPRepl.MAX_OUTPUT_CHARS * 2) * "\nTAIL-MARKER"
        result = MCPRepl.maybe_truncate_output(big)
        @test length(result) < length(big)
        @test startswith(result, "HEAD-MARKER")          # head preserved (holds ERROR: line)
        @test endswith(result, "TAIL-MARKER")            # tail preserved
        @test occursin("output truncated", result)
        @test occursin("Full output written to:", result)

        # The pointed-to file exists and holds the complete original output
        m = match(r"Full output written to: (\S+)", result)
        @test m !== nothing
        path = m.captures[1]
        @test isfile(path)
        @test read(path, String) == big
        rm(path; force = true)

        # Unicode boundaries are handled (no invalid-index crash)
        unicode_big = repeat("λ→∑", MCPRepl.MAX_OUTPUT_CHARS)
        u_result = MCPRepl.maybe_truncate_output(unicode_big)
        @test length(u_result) < length(unicode_big)
        um = match(r"Full output written to: (\S+)", u_result)
        um !== nothing && rm(um.captures[1]; force = true)
    end

    @testset "Word-id assignment" begin
        # Deterministic: same project dir -> same word (stable across restarts)
        w1 = MCPRepl.wordid_for("/some/project/foo", String[])
        w2 = MCPRepl.wordid_for("/some/project/foo", String[])
        @test w1 == w2
        @test w1 in MCPRepl.WORDLIST

        # Collision handling: if the deterministic word is taken, pick another
        w3 = MCPRepl.wordid_for("/some/project/foo", [w1])
        @test w3 != w1
        @test w3 in MCPRepl.WORDLIST

        # Exhaustion: when every word is taken by a live REPL, error loudly rather
        # than silently hand out a duplicate word-id.
        @test_throws ErrorException MCPRepl.wordid_for("/some/project/foo",
                                                       copy(MCPRepl.WORDLIST))
    end

    @testset "Registry reaping" begin
        # A live pid (our own) is alive; a bogus/never-used pid is dead.
        @test MCPRepl._pid_alive(getpid())
        @test !MCPRepl._pid_alive(2_000_000_000)  # unused, out of typical pid range
        @test !MCPRepl._pid_alive(0)
        @test !MCPRepl._pid_alive(-1)

        # reap_stale_registry! deletes dead-pid records, keeps live ones, and
        # leaves unparseable files untouched.
        mktempdir() do dir
            withenv("MCPREPL_REGISTRY_DIR" => dir) do
                @test MCPRepl.registry_dir() == dir
                write(joinpath(dir, "live.json"),
                      JSON.json(Dict("pid" => getpid(), "word" => "otter")))
                write(joinpath(dir, "dead.json"),
                      JSON.json(Dict("pid" => 2_000_000_000, "word" => "badger")))
                write(joinpath(dir, "partial.json"), "{not valid json")
                write(joinpath(dir, "nopid.json"),
                      JSON.json(Dict("word" => "heron")))

                MCPRepl.reap_stale_registry!()

                @test isfile(joinpath(dir, "live.json"))      # live pid kept
                @test !isfile(joinpath(dir, "dead.json"))     # dead pid pruned
                @test isfile(joinpath(dir, "partial.json"))   # unparseable left alone
                @test isfile(joinpath(dir, "nopid.json"))     # no pid -> left alone

                # After reaping, the dead REPL's word is gone; the live one and
                # the (untouched) no-pid record's word remain.
                claimed = Set(MCPRepl._claimed_words())
                @test "otter" in claimed        # live pid
                @test "heron" in claimed        # no-pid record left in place
                @test !("badger" in claimed)    # dead pid reaped
            end
        end
    end

    @testset "Port selection" begin
        # A free preferred port is returned as-is.
        freeport = let s = Sockets.listen(Sockets.localhost, 0)
            p = Int(Sockets.getsockname(s)[2]); close(s); p
        end
        @test MCPRepl.choose_port(freeport) == freeport

        # If the preferred port is busy, fall back to a different (ephemeral) one.
        held = Sockets.listen(Sockets.localhost, 0)
        heldport = Int(Sockets.getsockname(held)[2])
        try
            fallback = MCPRepl.choose_port(heldport)
            @test fallback != heldport
            @test 1 <= fallback <= 65535
        finally
            close(held)
        end
    end

    @testset "Registry file lifecycle" begin
        # register_repl! writes a <pid>.json we can parse; unregister removes it.
        MCPRepl.register_repl!(65123, "otter")
        f = MCPRepl._REGISTRY_FILE[]
        @test f !== nothing
        @test isfile(f)
        data = JSON.parse(read(f, String))
        @test data["pid"] == getpid()
        @test data["port"] == 65123
        @test data["word"] == "otter"
        @test haskey(data, "project_dir")
        # A shared REPL is not private and carries default private-tracking fields.
        @test data["private"] == false
        @test haskey(data, "spawn_token")
        @test data["owner_pid"] == 0
        MCPRepl.unregister_repl!()
        @test !isfile(f)
        @test MCPRepl._REGISTRY_FILE[] === nothing

        # A private REPL records private=true plus the spawn_token/owner_pid the
        # adapter passes via the environment, so the adapter can match and reap it.
        withenv("MCPREPL_SPAWN_TOKEN" => "tok-123", "MCPREPL_OWNER_PID" => "4242") do
            MCPRepl.register_repl!(65124, "beaver"; private = true)
            f2 = MCPRepl._REGISTRY_FILE[]
            data2 = JSON.parse(read(f2, String))
            @test data2["private"] == true
            @test data2["spawn_token"] == "tok-123"
            @test data2["owner_pid"] == 4242
            MCPRepl.unregister_repl!()
        end
    end

    @testset "Adapter routing (python)" begin
        # The multiplexing router lives in the Python adapter; exercise its logic
        # (rank, resolution branches, identity guard) via its own fast,
        # Julia-free test. Skip cleanly if python3 isn't on PATH.
        py = Sys.which("python3")
        if py === nothing
            @info "python3 not found; skipping adapter routing tests"
        else
            script = joinpath(@__DIR__, "adapter_routing_test.py")
            @test success(run(pipeline(`$py $script`; stdout = stdout, stderr = stderr)))
        end
    end

    @testset "Install-prompt suppression" begin
        hooks = MCPRepl.REPL.install_packages_hooks
        saved = copy(hooks)
        try
            MCPRepl.suppress_install_prompts!()
            # Exactly one no-op hook that reports "handled" (true) without prompting,
            # so a missing `using Foo` surfaces Base's ArgumentError instead of stdin.
            @test length(hooks) == 1
            @test hooks[1](Symbol[:SomeMissingPkg]) === true
        finally
            empty!(hooks)
            append!(hooks, saved)
        end
    end
end
