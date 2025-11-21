using ReTest
using HTTP
using JSON

# Import the proxy module
include("../src/proxy.jl")
using .Proxy

@testset "Proxy MCP Tool Routing" begin
    @testset "Route tools/list through proxy" begin
        empty!(Proxy.REPL_REGISTRY)

        # Start a mock MCP server that responds to tools/list
        mock_port = 19001
        mock_server = HTTP.serve!(mock_port; verbose=false) do req
            body = String(req.body)
            request = JSON.parse(body)

            if request["method"] == "tools/list"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict(
                        "tools" => [
                            Dict("name" => "test_tool", "description" => "A test tool"),
                        ],
                    ),
                )
                return HTTP.Response(200, JSON.json(response))
            end

            return HTTP.Response(404, JSON.json(Dict("error" => "Unknown method")))
        end

        try
            # Register the mock backend
            Proxy.register_repl("test-backend", mock_port; pid=Int(getpid()))

            # Create a proxy request
            req_headers =
                ["Content-Type" => "application/json", "X-MCPRepl-Target" => "test-backend"]
            req_body = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/list",
                    "params" => Dict(),
                ),
            )

            proxy_req = HTTP.Request("POST", "/", req_headers, req_body)

            # Call handle_request
            response = Proxy.handle_request(proxy_req)

            # Verify response
            @test response.status == 200

            body = String(response.body)
            json_response = JSON.parse(body)

            @test haskey(json_response, "result")
            @test haskey(json_response["result"], "tools")
            @test length(json_response["result"]["tools"]) == 1
            @test json_response["result"]["tools"][1]["name"] == "test_tool"

        finally
            close(mock_server)
        end
    end

    @testset "Route tools/call through proxy" begin
        empty!(Proxy.REPL_REGISTRY)

        # Start a mock MCP server that responds to tools/call
        mock_port = 19002
        mock_server = HTTP.serve!(mock_port; verbose=false) do req
            body = String(req.body)
            request = JSON.parse(body)

            if request["method"] == "tools/call"
                tool_name = request["params"]["name"]
                arguments = request["params"]["arguments"]

                # Mock tool execution
                if tool_name == "reverse_text"
                    text = arguments["text"]
                    result = reverse(text)

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => Dict(
                            "content" => [Dict("type" => "text", "text" => result)],
                        ),
                    )
                    return HTTP.Response(200, JSON.json(response))
                end
            end

            return HTTP.Response(404, JSON.json(Dict("error" => "Unknown method or tool")))
        end

        try
            # Register the mock backend
            Proxy.register_repl("test-backend-2", mock_port; pid=Int(getpid()))

            # Create a proxy request for tools/call
            req_headers = [
                "Content-Type" => "application/json",
                "X-MCPRepl-Target" => "test-backend-2",
            ]
            req_body = JSON.json(
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

            proxy_req = HTTP.Request("POST", "/", req_headers, req_body)

            # Call handle_request
            response = Proxy.handle_request(proxy_req)

            # Verify response
            @test response.status == 200

            body = String(response.body)
            json_response = JSON.parse(body)

            @test haskey(json_response, "result")
            @test haskey(json_response["result"], "content")
            @test json_response["result"]["content"][1]["text"] == "olleh"

        finally
            close(mock_server)
        end
    end
end
