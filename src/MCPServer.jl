# Tool definition structure
struct MCPTool
    name::String
    description::String
    parameters::Dict{String, Any}
    handler::Function
end

# Server with tool registry
struct MCPServer
    port::Int
    server::HTTP.Server
    tools::Dict{String, MCPTool}
end

# Create request handler with access to tools
function create_handler(tools::Dict{String, MCPTool}, port::Int)
    return function handle_request(req::HTTP.Request)
        try
            # Handle OAuth well-known metadata requests first (before JSON parsing)
            if req.target == "/.well-known/oauth-authorization-server"
                oauth_metadata = Dict(
                    "issuer" => "http://localhost:$port",
                    "authorization_endpoint" => "http://localhost:$port/oauth/authorize",
                    "token_endpoint" => "http://localhost:$port/oauth/token",
                    "grant_types_supported" => ["authorization_code"],
                    "response_types_supported" => ["code"],
                    "scopes_supported" => ["read", "write"]
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(oauth_metadata))
            end

            # Parse JSON-RPC request
            body = String(req.body)

            # Handle empty body (like GET requests)
            if isempty(body)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => nothing,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body"
                    )
                )
                return HTTP.Response(400, ["Content-Type" => "application/json"], JSON3.write(error_response))
            end

            request = JSON3.read(body)

            # Check if method field exists
            if !haskey(request, :method)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, :id, nothing),
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - missing method field"
                    )
                )
                return HTTP.Response(400, ["Content-Type" => "application/json"], JSON3.write(error_response))
            end

            # Handle initialization
            if request.method == "initialize"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request.id,
                    "result" => Dict(
                        "protocolVersion" => "2024-11-05",
                        "capabilities" => Dict(
                            "tools" => Dict()
                        ),
                        "serverInfo" => Dict(
                            "name" => "julia-mcp-server",
                            "version" => "1.0.0"
                        )
                    )
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response))
            end

            # Handle initialized notification
            if request.method == "notifications/initialized"
                # This is a notification, no response needed
                return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
            end


            # Handle tool listing
            if request.method == "tools/list"
                tool_list = [
                    Dict(
                        "name" => tool.name,
                        "description" => tool.description,
                        "inputSchema" => tool.parameters
                    ) for tool in values(tools)
                ]

                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request.id,
                    "result" => Dict("tools" => tool_list)
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response))
            end

            # Handle tool calls
            if request.method == "tools/call"
                tool_name = request.params.name
                if haskey(tools, tool_name)
                    tool = tools[tool_name]
                    args = get(request.params, :arguments, Dict())

                    # Call the tool handler
                    result_text = tool.handler(args)

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request.id,
                        "result" => Dict(
                            "content" => [
                                Dict(
                                    "type" => "text",
                                    "text" => result_text
                                )
                            ]
                        )
                    )
                    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response))
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request.id,
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Tool not found: $tool_name"
                        )
                    )
                    return HTTP.Response(404, ["Content-Type" => "application/json"], JSON3.write(error_response))
                end
            end

            # Method not found
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, :id, nothing),
                "error" => Dict(
                    "code" => -32601,
                    "message" => "Method not found"
                )
            )
            return HTTP.Response(404, ["Content-Type" => "application/json"], JSON3.write(error_response))

        catch e
            # Internal error
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => nothing,
                "error" => Dict(
                    "code" => -32603,
                    "message" => "Internal error: $e"
                )
            )
            return HTTP.Response(500, ["Content-Type" => "application/json"], JSON3.write(error_response))
        end
    end
end

# Convenience function to create a simple text parameter schema
function text_parameter(name::String, description::String, required::Bool = true)
    schema = Dict(
        "type" => "object",
        "properties" => Dict(
            name => Dict(
                "type" => "string",
                "description" => description
            )
        )
    )
    if required
        schema["required"] = [name]
    end
    return schema
end

function start_mcp_server(tools::Vector{MCPTool}, port::Int = 3000)
    tools_dict = Dict(tool.name => tool for tool in tools)
    handler = create_handler(tools_dict, port)
    server = HTTP.serve!(handler, port)
    println("MCP Server running on port $port with $(length(tools)) tools")
    println("To use with Claude Code, run: claude mcp add julia-repl http://localhost:$port --transport http")
    return MCPServer(port, server, tools_dict)
end

function stop_mcp_server(server::MCPServer)
    HTTP.close(server.server)
    println("MCP Server stopped")
end
