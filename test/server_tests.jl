using Test
using MCPRepl
using MCPRepl: MCPTool
using HTTP
using JSON
using Dates

# Create test tools
time_tool = MCPTool(
    "get_time",
    "Get current time in specified format",
    MCPRepl.text_parameter(
        "format",
        "DateTime format string (e.g., 'yyyy-mm-dd HH:MM:SS')",
    ),
    args -> Dates.format(now(), get(args, "format", "yyyy-mm-dd HH:MM:SS")),
)

reverse_tool = MCPTool(
    "reverse_text",
    "Reverse the input text",
    MCPRepl.text_parameter("text", "Text to reverse"),
    args -> reverse(get(args, "text", "")),
)

calc_tool = MCPTool(
    "calculate",
    "Evaluate a simple Julia expression",
    MCPRepl.text_parameter(
        "expression",
        "Julia expression to evaluate (e.g., '2 + 3 * 4')",
    ),
    function (args)
        try
            expr = Meta.parse(get(args, "expression", "0"))
            result = eval(expr)
            string(result)
        catch e
            "Error: $e"
        end
    end,
)

tools = [time_tool, reverse_tool, calc_tool]

@testset "Server Startup and Shutdown" begin
    # Start server on test port (use port that shouldn't conflict)
    test_port = 13001
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

@testset "Invalid Requests" begin
    # Start server for invalid request tests
    test_port = 13002
    server = MCPRepl.start_mcp_server(tools, test_port)

    # Give server time to start
    sleep(0.1)

    try
        # Test empty body - HTTP.jl throws exception for 400 status by default
        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            "";
            status_exception = false,
        )

        @test response.status == 400

        # Parse error response
        body = String(response.body)
        json_response = JSON.parse(body)

        @test haskey(json_response, :error)
        @test occursin("empty body", json_response.error.message)

    finally
        # Always stop server
        MCPRepl.stop_mcp_server(server)
        sleep(0.1)
    end
end

@testset "Tool Listing" begin
    # Start server for tool listing tests
    test_port = 13003
    server = MCPRepl.start_mcp_server(tools, test_port)

    # Give server time to start
    sleep(0.1)

    try
        # Test tools/list request
        request_body =
            JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"))

        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            request_body,
        )

        @test response.status == 200

        # Parse response
        body = String(response.body)
        json_response = JSON.parse(body)

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
    test_port = 13004
    server = MCPRepl.start_mcp_server(tools, test_port)

    # Give server time to start
    sleep(0.1)

    try
        # Test reverse_text tool
        request_body = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "reverse_text",
                    "arguments" => Dict("text" => "hello"),
                ),
            ),
        )

        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            request_body,
        )

        @test response.status == 200

        # Parse response
        body = String(response.body)
        json_response = JSON.parse(body)

        @test json_response.result.content[1].text == "olleh"

        # Test calculate tool
        request_body = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 3,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "calculate",
                    "arguments" => Dict("expression" => "2 + 3 * 4"),
                ),
            ),
        )

        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json"],
            request_body,
        )

        @test response.status == 200

        # Parse response
        body = String(response.body)
        json_response = JSON.parse(body)

        @test json_response.result.content[1].text == "14"

    finally
        # Always stop server
        MCPRepl.stop_mcp_server(server)
        sleep(0.1)
    end
end

@testset "SSE Streaming" begin
    # Create a simple streaming tool for testing
    stream_tool = MCPTool(
        "stream_test",
        "Test tool that supports streaming",
        Dict("type" => "object", "properties" => Dict(), "required" => []),
        (args, stream_channel = nothing) -> begin
            if stream_channel !== nothing
                # Send progress notification
                put!(
                    stream_channel,
                    JSON.json(
                        Dict(
                            "jsonrpc" => "2.0",
                            "method" => "notifications/progress",
                            "params" =>
                                Dict("progress" => 50, "message" => "Half done"),
                        ),
                    ),
                )
            end
            return "Streaming test completed"
        end,
    )

    test_port = 13005
    server = MCPRepl.start_mcp_server([stream_tool], test_port)
    sleep(0.1)

    try
        # Test with SSE Accept header
        request_body = JSON.json(
            Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/call",
                "params" => Dict("name" => "stream_test", "arguments" => Dict()),
            ),
        )

        # Make request with SSE Accept header
        response = HTTP.post(
            "http://localhost:$test_port/",
            ["Content-Type" => "application/json", "Accept" => "text/event-stream"],
            request_body,
        )

        @test response.status == 200
        @test HTTP.header(response, "Content-Type") == "text/event-stream"

        # Response should contain SSE formatted events
        body = String(response.body)
        @test contains(body, "event: message")
        @test contains(body, "data:")
        @test contains(body, "Half done")
        @test contains(body, "Streaming test completed")

    finally
        MCPRepl.stop_mcp_server(server)
        sleep(0.1)
    end
end
