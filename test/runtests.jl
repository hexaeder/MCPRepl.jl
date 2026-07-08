using Test
using MCPRepl
using MCPRepl: MCPTool
using HTTP
using JSON3
using Dates

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
                json_response = JSON3.read(body)

                @test json_response.jsonrpc == "2.0"
                @test json_response.error.code == -32600
                @test occursin("Invalid Request", json_response.error.message)
                @test occursin("empty body", json_response.error.message)
                @test occursin("empty body", json_response.error.message)

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
                request_body = JSON3.write(Dict(
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
                json_response = JSON3.read(body)

                @test json_response.jsonrpc == "2.0"
                @test json_response.id == 1
                @test haskey(json_response.result, "tools")
                @test length(json_response.result.tools) == 3

                # Check tool names
                tool_names = [tool.name for tool in json_response.result.tools]
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
                request_body = JSON3.write(Dict(
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
                json_response = JSON3.read(body)

                @test json_response.jsonrpc == "2.0"
                @test json_response.id == 2
                @test haskey(json_response.result, "content")
                @test length(json_response.result.content) == 1
                @test json_response.result.content[1].type == "text"
                @test json_response.result.content[1].text == "olleh"

                # Test calculate tool
                request_body = JSON3.write(Dict(
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
                json_response = JSON3.read(body)

                @test json_response.result.content[1].text == "14"

            finally
                # Always stop server
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
