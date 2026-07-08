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
        # Parse JSON-RPC request
        body = String(req.body)

        try
            # This server is not a standalone MCP endpoint: the stdio adapter
            # (mcp-julia-adapter) is the MCP server the client talks to. Julia only
            # answers the plain JSON-RPC methods the adapter forwards — tools/list,
            # tools/call, ping — plus a helpful empty-body error. The MCP handshake
            # (initialize/serverInfo) and any OAuth dance are owned by the adapter.

            # Handle empty body (like GET requests)
            if isempty(body)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body"
                    )
                )
                return HTTP.Response(400, ["Content-Type" => "application/json"], JSON.json(error_response))
            end

            request = JSON.parse(body)

            # Check if method field exists
            if !haskey(request, "method")
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", 0),
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - missing method field"
                    )
                )
                return HTTP.Response(400, ["Content-Type" => "application/json"], JSON.json(error_response))
            end

            # Handle notifications (no id field) — no response body needed
            if !haskey(request, "id")
                return HTTP.Response(204, [], "")
            end

            # Handle ping
            if request["method"] == "ping"
                response = Dict("jsonrpc" => "2.0", "id" => request["id"], "result" => Dict())
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
            end


            # Handle tool listing
            if request["method"] == "tools/list"
                tool_list = [
                    Dict(
                        "name" => tool.name,
                        "description" => tool.description,
                        "inputSchema" => tool.parameters
                    ) for tool in values(tools)
                ]

                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("tools" => tool_list)
                )
                return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
            end

            # Handle tool calls
            if request["method"] == "tools/call"
                tool_name = request["params"]["name"]
                if haskey(tools, tool_name)
                    tool = tools[tool_name]
                    args = get(request["params"], "arguments", Dict())

                    # Call the tool handler
                    result_text = tool.handler(args)

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => Dict(
                            "content" => [
                                Dict(
                                    "type" => "text",
                                    "text" => result_text
                                )
                            ]
                        )
                    )
                    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(response))
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Tool not found: $tool_name"
                        )
                    )
                    return HTTP.Response(404, ["Content-Type" => "application/json"], JSON.json(error_response))
                end
            end

            # Method not found
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", 0),
                "error" => Dict(
                    "code" => -32601,
                    "message" => "Method not found"
                )
            )
            return HTTP.Response(404, ["Content-Type" => "application/json"], JSON.json(error_response))

        catch e
            # Internal error - show in REPL and return to client
            printstyled("\nMCP Server error: $e\n", color=:red)

            # Try to get the original request ID for proper JSON-RPC error response
            request_id = 0  # Default to 0 instead of nothing to satisfy JSON-RPC schema
            try
                if !isempty(body)
                    parsed_request = JSON.parse(body)
                    # Only use the request ID if it's a valid JSON-RPC ID (string or number)
                    raw_id = get(parsed_request, "id", 0)
                    if raw_id isa Union{String, Number}
                        request_id = raw_id
                    end
                end
            catch
                # If we can't parse the request, use default ID
                request_id = 0
            end

            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict(
                    "code" => -32603,
                    "message" => "Internal error: $e"
                )
            )
            return HTTP.Response(500, ["Content-Type" => "application/json"], JSON.json(error_response))
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

function start_mcp_server(tools::Vector{MCPTool}, port::Int = 3000; verbose::Bool = true, word::Union{Nothing,AbstractString} = nothing)
    tools_dict = Dict(tool.name => tool for tool in tools)
    handler = create_handler(tools_dict, port)

    # Suppress HTTP server logging
    server = HTTP.serve!(handler, port; verbose=false)

    # This is a REPL bridge, not a standalone MCP server: the stdio adapter is the
    # server clients connect to, and it discovers this REPL through the registry.
    # So the banner just confirms the REPL registered itself and how to reach it.
    if verbose
        # Nudge the user to register the adapter if neither client has it configured.
        claude_status = MCPRepl.check_claude_status()
        gemini_status = MCPRepl.check_gemini_status()
        if claude_status == :not_configured || gemini_status == :not_configured
            println("💡 Call MCPRepl.setup() to register the Julia REPL adapter with your MCP client.")
            println()
        end

        label = word === nothing ? "" : "'$word' "
        println("🚀 Julia REPL $(label)ready on port $port ($(length(tools)) tools) — discoverable by the MCP adapter.")
        if word !== nothing
            portnote = port == 3000 ? "" : " (port 3000 was busy — using $port)"
            println("   🔖 This REPL is '$word'$portnote")
            println("   📇 Registry: $(MCPRepl.registry_dir())")
        end
        println()  # Add blank line at end of splash
    else
        label = word === nothing ? "" : "'$word' "
        println("Julia REPL $(label)ready on port $port ($(length(tools)) tools)")
    end

    return MCPServer(port, server, tools_dict)
end

function stop_mcp_server(server::MCPServer)
    HTTP.close(server.server)
    println("MCP Server stopped")
end
