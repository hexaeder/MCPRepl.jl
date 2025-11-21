using ReTest
using HTTP
using JSON
using Sockets

# Start the proxy
push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))
using MCPRepl

# Import Proxy module to access registry
include("../src/proxy.jl")

@testset "Proxy with Real MCPRepl Backend" begin
    # Start proxy in background
    proxy_port = 3000
    if !Proxy.is_server_running(proxy_port)
        Proxy.start_server(proxy_port; background=true)
        sleep(1)  # Give proxy time to start
    end
    @test Proxy.is_server_running(proxy_port)

    # Start a real MCPRepl backend on a different port using the same pattern as proxy_routing_tests.jl
    backend_port = 19005

    # Create handler function
    function backend_handler(req)
        try
            body = String(req.body)
            request_data = JSON.parse(body)

            # Handle tools/list
            if request_data["method"] == "tools/list"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request_data["id"],
                    "result" => Dict(
                        "tools" => [
                            Dict(
                                "name" => "reverse_text",
                                "description" => "Reverses the input text",
                                "inputSchema" => Dict(
                                    "type" => "object",
                                    "properties" => Dict(
                                        "text" => Dict("type" => "string"),
                                    ),
                                    "required" => ["text"],
                                ),
                            ),
                            Dict(
                                "name" => "calculate",
                                "description" => "Evaluates a mathematical expression",
                                "inputSchema" => Dict(
                                    "type" => "object",
                                    "properties" => Dict(
                                        "expression" => Dict("type" => "string"),
                                    ),
                                    "required" => ["expression"],
                                ),
                            ),
                        ],
                    ),
                )
                return HTTP.Response(200, JSON.json(response))
            end

            # Handle tools/call
            if request_data["method"] == "tools/call"
                tool_name = request_data["params"]["name"]
                tool_args = request_data["params"]["arguments"]

                result = if tool_name == "reverse_text"
                    reverse(tool_args["text"])
                elseif tool_name == "calculate"
                    string(eval(Meta.parse(tool_args["expression"])))
                else
                    "Unknown tool: $tool_name"
                end

                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request_data["id"],
                    "result" =>
                        Dict("content" => [Dict("type" => "text", "text" => result)]),
                )
                return HTTP.Response(200, JSON.json(response))
            end

            # Unknown method
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => get(request_data, "id", nothing),
                "error" => Dict(
                    "code" => -32601,
                    "message" => "Method not found: $(request_data["method"])",
                ),
            )
            return HTTP.Response(404, JSON.json(error_response))
        catch e
            @error "Backend error" exception = (e, catch_backtrace())
            return HTTP.Response(500, "Internal server error: $e")
        end
    end

    # Start server using HTTP.serve!
    backend_server =
        HTTP.serve!(backend_handler, "127.0.0.1", backend_port; verbose=false)
    sleep(0.5)  # Give backend time to start

    # Register the backend with proxy
    backend_id = "real-backend"
    registration = Dict(
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "proxy/register",
        "params" => Dict(
            "id" => backend_id,
            "port" => backend_port,
            "pid" => getpid(),
            "metadata" => Dict("type" => "test-backend"),
        ),
    )

    reg_response = HTTP.post(
        "http://127.0.0.1:$proxy_port/",
        ["Content-Type" => "application/json"],
        JSON.json(registration),
    )
    @test reg_response.status == 200

    # Test tools/list through proxy
    @testset "Real Backend - tools/list" begin
        list_request = Dict("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list")

        response = HTTP.post(
            "http://127.0.0.1:$proxy_port/",
            ["Content-Type" => "application/json", "X-MCPRepl-Target" => backend_id],
            JSON.json(list_request),
        )

        @test response.status == 200
        json_response = JSON.parse(String(response.body))
        @test haskey(json_response, "result")
        @test haskey(json_response["result"], "tools")
        @test length(json_response["result"]["tools"]) == 2
        @test json_response["result"]["tools"][1]["name"] == "reverse_text"
        @test json_response["result"]["tools"][2]["name"] == "calculate"
    end

    # Test tools/call - reverse_text through proxy
    @testset "Real Backend - tools/call reverse_text" begin
        call_request = Dict(
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => Dict(
                "name" => "reverse_text",
                "arguments" => Dict("text" => "Hello World"),
            ),
        )

        response = HTTP.post(
            "http://127.0.0.1:$proxy_port/",
            ["Content-Type" => "application/json", "X-MCPRepl-Target" => backend_id],
            JSON.json(call_request),
        )

        @test response.status == 200
        json_response = JSON.parse(String(response.body))
        @test haskey(json_response, "result")
        @test haskey(json_response["result"], "content")
        @test json_response["result"]["content"][1]["text"] == "dlroW olleH"
    end

    # Test tools/call - calculate through proxy
    @testset "Real Backend - tools/call calculate" begin
        call_request = Dict(
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => Dict(
                "name" => "calculate",
                "arguments" => Dict("expression" => "2 + 2 * 3"),
            ),
        )

        response = HTTP.post(
            "http://127.0.0.1:$proxy_port/",
            ["Content-Type" => "application/json", "X-MCPRepl-Target" => backend_id],
            JSON.json(call_request),
        )

        @test response.status == 200
        json_response = JSON.parse(String(response.body))
        @test haskey(json_response, "result")
        @test haskey(json_response["result"], "content")
        @test json_response["result"]["content"][1]["text"] == "8"
    end

    # Cleanup
    try
        close(backend_server)
    catch
        # Server might already be closed
    end

    # Unregister backend
    try
        unreg_request = Dict(
            "jsonrpc" => "2.0",
            "id" => 99,
            "method" => "proxy/unregister",
            "params" => Dict("id" => backend_id),
        )
        HTTP.post(
            "http://127.0.0.1:$proxy_port/",
            ["Content-Type" => "application/json"],
            JSON.json(unreg_request),
        )
    catch
        # Proxy might be shutting down
    end
end
