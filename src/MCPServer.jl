using HTTP

# Global storage for active streaming responses (request_id => Stream)
const ACTIVE_STREAMS = Dict{String,HTTP.Stream}()
const STREAM_LOCK = ReentrantLock()

# Tool definition structure
struct MCPTool
    name::String
    description::String
    parameters::Dict{String,Any}
    handler::Function
end

# Server with tool registry
struct MCPServer
    port::Int
    server::HTTP.Server
    tools::Dict{String,MCPTool}
end

# Create request handler with access to tools
function create_handler(tools::Dict{String,MCPTool}, port::Int)
    return function handle_request(req::HTTP.Request)
        # Parse JSON-RPC request
        body = String(req.body)

        try
            # Handle VS Code response endpoint (for bidirectional communication)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON3.read(body)
                    request_id = get(response_data, :request_id, nothing)
                    
                    if request_id === nothing
                        return HTTP.Response(
                            400,
                            ["Content-Type" => "application/json"],
                            JSON3.write(Dict("error" => "Missing request_id")),
                        )
                    end
                    
                    result = get(response_data, :result, nothing)
                    error = get(response_data, :error, nothing)
                    
                    # Store the response using MCPRepl function
                    MCPRepl.store_vscode_response(string(request_id), result, error)
                    
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON3.write(Dict("status" => "ok")),
                    )
                catch e
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON3.write(Dict("error" => "Failed to process response: $e")),
                    )
                end
            end
            
            # Handle OAuth well-known metadata requests first (before JSON parsing)
            if req.target == "/.well-known/oauth-authorization-server"
                oauth_metadata = Dict(
                    "issuer" => "http://localhost:$port",
                    "authorization_endpoint" => "http://localhost:$port/oauth/authorize",
                    "token_endpoint" => "http://localhost:$port/oauth/token",
                    "registration_endpoint" => "http://localhost:$port/oauth/register",
                    "grant_types_supported" =>
                        ["authorization_code", "client_credentials"],
                    "response_types_supported" => ["code"],
                    "scopes_supported" => ["read", "write"],
                    "client_registration_types_supported" => ["dynamic"],
                    "code_challenge_methods_supported" => ["S256"],
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON3.write(oauth_metadata),
                )
            end

            # Handle dynamic client registration
            if req.target == "/oauth/register" && req.method == "POST"
                client_id = "claude-code-" * string(rand(UInt64), base = 16)
                client_secret = string(rand(UInt128), base = 16)

                registration_response = Dict(
                    "client_id" => client_id,
                    "client_secret" => client_secret,
                    "client_id_issued_at" => Int(floor(time())),
                    "grant_types" => ["authorization_code", "client_credentials"],
                    "response_types" => ["code"],
                    "redirect_uris" => [
                        "http://localhost:8080/callback",
                        "http://127.0.0.1:8080/callback",
                    ],
                    "token_endpoint_auth_method" => "client_secret_basic",
                    "scope" => "read write",
                )
                return HTTP.Response(
                    201,
                    ["Content-Type" => "application/json"],
                    JSON3.write(registration_response),
                )
            end

            # Handle authorization endpoint
            if startswith(req.target, "/oauth/authorize")
                # For local development, auto-approve all requests
                uri = HTTP.URI(req.target)
                query_params = HTTP.queryparams(uri)
                redirect_uri = get(query_params, "redirect_uri", "")
                state = get(query_params, "state", "")

                auth_code = "auth_" * string(rand(UInt64), base = 16)
                redirect_url = "$redirect_uri?code=$auth_code&state=$state"

                return HTTP.Response(302, ["Location" => redirect_url], "")
            end

            # Handle token endpoint
            if req.target == "/oauth/token" && req.method == "POST"
                access_token = "access_" * string(rand(UInt128), base = 16)

                token_response = Dict(
                    "access_token" => access_token,
                    "token_type" => "Bearer",
                    "expires_in" => 3600,
                    "scope" => "read write",
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON3.write(token_response),
                )
            end

            # Handle empty body (like GET requests)
            if isempty(body)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body",
                    ),
                )
                return HTTP.Response(
                    400,
                    ["Content-Type" => "application/json"],
                    JSON3.write(error_response),
                )
            end

            request = JSON3.read(body)

            # Check if method field exists
            if !haskey(request, :method)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, :id, 0),
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - missing method field",
                    ),
                )
                return HTTP.Response(
                    400,
                    ["Content-Type" => "application/json"],
                    JSON3.write(error_response),
                )
            end

            # Handle initialization
            if request.method == "initialize"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request.id,
                    "result" => Dict(
                        "protocolVersion" => "2024-11-05",
                        "capabilities" => Dict("tools" => Dict()),
                        "serverInfo" => Dict(
                            "name" => "julia-mcp-server",
                            "version" => "1.0.0",
                        ),
                    ),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON3.write(response),
                )
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
                        "inputSchema" => tool.parameters,
                    ) for tool in values(tools)
                ]

                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request.id,
                    "result" => Dict("tools" => tool_list),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON3.write(response),
                )
            end

            # Handle tool calls
            if request.method == "tools/call"
                tool_name = request.params.name
                if haskey(tools, tool_name)
                    tool = tools[tool_name]
                    args = get(request.params, :arguments, Dict())
                    
                    # Check if streaming is requested
                    enable_streaming = get(args, :stream, false)
                    
                    if enable_streaming
                        # Create a channel for streaming
                        request_id = string(request.id)
                        stream_channel = Channel{String}(32)  # Buffer up to 32 events
                        
                        lock(SSE_LOCK) do
                            SSE_STREAMS[request_id] = stream_channel
                        end
                        
                        # Start async task to run the tool and stream results
                        @async begin
                            try
                                # Call tool handler with streaming channel
                                # Try to call with stream_channel if handler accepts it
                                result_text = try
                                    tool.handler(args, stream_channel)
                                catch e
                                    if isa(e, MethodError)
                                        # Handler doesn't support streaming, fall back
                                        tool.handler(args)
                                    else
                                        rethrow(e)
                                    end
                                end
                                
                                # Send final result
                                final_event = JSON3.write(Dict(
                                    "type" => "complete",
                                    "content" => result_text
                                ))
                                put!(stream_channel, final_event)
                            catch e
                                # Send error event
                                error_event = JSON3.write(Dict(
                                    "type" => "error",
                                    "error" => string(e)
                                ))
                                put!(stream_channel, error_event)
                            finally
                                close(stream_channel)
                            end
                        end
                        
                        # Return SSE endpoint info
                        response = Dict(
                            "jsonrpc" => "2.0",
                            "id" => request.id,
                            "result" => Dict(
                                "streaming" => true,
                                "sse_endpoint" => "/sse/$request_id",
                                "content" => [Dict("type" => "text", "text" => "Streaming started at /sse/$request_id")]
                            ),
                        )
                        return HTTP.Response(
                            200,
                            ["Content-Type" => "application/json"],
                            JSON3.write(response),
                        )
                    else
                        # Non-streaming mode (original behavior)
                        result_text = tool.handler(args)

                        response = Dict(
                            "jsonrpc" => "2.0",
                            "id" => request.id,
                            "result" => Dict(
                                "content" =>
                                    [Dict("type" => "text", "text" => result_text)],
                            ),
                        )
                        return HTTP.Response(
                            200,
                            ["Content-Type" => "application/json"],
                            JSON3.write(response),
                        )
                    end
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request.id,
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Tool not found: $tool_name",
                        ),
                    )
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "application/json"],
                        JSON3.write(error_response),
                    )
                end
            end

            # Method not found
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, :id, 0),
                "error" => Dict("code" => -32601, "message" => "Method not found"),
            )
            return HTTP.Response(
                404,
                ["Content-Type" => "application/json"],
                JSON3.write(error_response),
            )

        catch e
            # Internal error - show in REPL and return to client
            printstyled("\nMCP Server error: $e\n", color = :red)

            # Try to get the original request ID for proper JSON-RPC error response
            request_id = 0  # Default to 0 instead of nothing to satisfy JSON-RPC schema
            try
                if !isempty(body)
                    parsed_request = JSON3.read(body)
                    # Only use the request ID if it's a valid JSON-RPC ID (string or number)
                    raw_id = get(parsed_request, :id, 0)
                    if raw_id isa Union{String,Number}
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
                "error" => Dict("code" => -32603, "message" => "Internal error: $e"),
            )
            return HTTP.Response(
                500,
                ["Content-Type" => "application/json"],
                JSON3.write(error_response),
            )
        end
    end
end

# Convenience function to create a simple text parameter schema
function text_parameter(name::String, description::String, required::Bool = true)
    schema = Dict(
        "type" => "object",
        "properties" =>
            Dict(name => Dict("type" => "string", "description" => description)),
    )
    if required
        schema["required"] = [name]
    end
    return schema
end

function start_mcp_server(tools::Vector{MCPTool}, port::Int = 3000; verbose::Bool = true)
    tools_dict = Dict(tool.name => tool for tool in tools)
    
    # Create a hybrid handler that supports both regular and streaming responses
    function hybrid_handler(http::HTTP.Stream)
        req = http.message
        
        # Read the request body
        body = String(read(http))
        
        try
            if isempty(body)
                HTTP.setstatus(http, 400)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 0,
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - empty body",
                    ),
                )
                write(http, JSON3.write(error_response))
                return nothing
            end
            
            request = JSON3.read(body)
            
            # Handle tool calls with potential streaming
            if request.method == "tools/call"
                tool_name = request.params.name
                if haskey(tools_dict, tool_name)
                    tool = tools_dict[tool_name]
                    args = get(request.params, :arguments, Dict())
                    
                    # Check Accept header for text/event-stream support
                    accept_header = ""
                    for (name, value) in req.headers
                        if lowercase(name) == "accept"
                            accept_header = lowercase(value)
                            break
                        end
                    end
                    client_supports_sse = contains(accept_header, "text/event-stream")
                    
                    # Enable streaming if client supports SSE (automatically) OR if explicitly requested
                    stream_requested = get(args, :stream, false)
                    enable_streaming = client_supports_sse || stream_requested
                    
                    if enable_streaming
                        # Set up SSE headers for streaming response
                        HTTP.setstatus(http, 200)
                        HTTP.setheader(http, "Content-Type" => "text/event-stream")
                        HTTP.setheader(http, "Cache-Control" => "no-cache")
                        HTTP.setheader(http, "Connection" => "keep-alive")
                        HTTP.startwrite(http)
                        
                        # Create channel for streaming
                        stream_channel = Channel{String}(32)
                        
                        # Start async task to run the tool
                        task = @async begin
                            try
                                # Call tool handler with streaming channel
                                result_text = try
                                    tool.handler(args, stream_channel)
                                catch e
                                    if isa(e, MethodError)
                                        # Handler doesn't support streaming, fall back
                                        tool.handler(args)
                                    else
                                        rethrow(e)
                                    end
                                end
                                
                                # Send final result
                                final_response = Dict(
                                    "jsonrpc" => "2.0",
                                    "id" => request.id,
                                    "result" => Dict(
                                        "content" => [Dict("type" => "text", "text" => result_text)]
                                    )
                                )
                                final_event = JSON3.write(final_response)
                                put!(stream_channel, final_event)
                            catch e
                                # Send error response
                                error_response = Dict(
                                    "jsonrpc" => "2.0",
                                    "id" => request.id,
                                    "error" => Dict(
                                        "code" => -32603,
                                        "message" => string(e)
                                    )
                                )
                                error_event = JSON3.write(error_response)
                                put!(stream_channel, error_event)
                            finally
                                close(stream_channel)
                            end
                        end
                        
                        # Stream events as they come
                        try
                            for event_data in stream_channel
                                # SSE format: event: message\ndata: {json}\n\n
                                write(http, "event: message\ndata: ")
                                write(http, event_data)
                                write(http, "\n\n")
                                flush(http)
                            end
                        catch e
                            @warn "Streaming error" exception=e
                        end
                        
                        return nothing
                    else
                        # Non-streaming mode (original behavior)
                        result_text = tool.handler(args)
                        
                        response = Dict(
                            "jsonrpc" => "2.0",
                            "id" => request.id,
                            "result" => Dict(
                                "content" => [Dict("type" => "text", "text" => result_text)],
                            ),
                        )
                        
                        HTTP.setstatus(http, 200)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON3.write(response))
                        return nothing
                    end
                else
                    HTTP.setstatus(http, 404)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request.id,
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Tool not found: $tool_name",
                        ),
                    )
                    write(http, JSON3.write(error_response))
                    return nothing
                end
            end
            
            # Handle other requests using the regular handler
            req_with_body = HTTP.Request(req.method, req.target, req.headers, body)
            handler = create_handler(tools_dict, port)
            response = handler(req_with_body)
            
            HTTP.setstatus(http, response.status)
            for (name, value) in response.headers
                HTTP.setheader(http, name => value)
            end
            HTTP.startwrite(http)
            write(http, response.body)
            return nothing
            
        catch e
            HTTP.setstatus(http, 500)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            
            request_id = try
                parsed = JSON3.read(body)
                get(parsed, :id, 0)
            catch
                0
            end
            
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict("code" => -32603, "message" => "Internal error: $e"),
            )
            write(http, JSON3.write(error_response))
            return nothing
        end
    end

    # Start server with stream=true to enable streaming responses
    server = HTTP.serve!(hybrid_handler, port; verbose = false, stream = true)

    if verbose
        # Check MCP status and show contextual message
        claude_status = MCPRepl.check_claude_status()
        gemini_status = MCPRepl.check_gemini_status()

        # Claude status
        if claude_status == :configured_http
            println("✅ Claude: MCP server configured (HTTP transport)")
        elseif claude_status == :configured_script
            println("✅ Claude: MCP server configured (script transport)")
        elseif claude_status == :configured_unknown
            println("✅ Claude: MCP server configured")
        elseif claude_status == :claude_not_found
            println("⚠️ Claude: Not found in PATH")
        else
            println("⚠️ Claude: MCP server not configured")
        end

        # Gemini status
        if gemini_status == :configured_http
            println("✅ Gemini: MCP server configured (HTTP transport)")
        elseif gemini_status == :configured_script
            println("✅ Gemini: MCP server configured (script transport)")
        elseif gemini_status == :configured_unknown
            println("✅ Gemini: MCP server configured")
        elseif gemini_status == :gemini_not_found
            println("⚠️ Gemini: Not found in PATH")
        else
            println("⚠️ Gemini: MCP server not configured")
        end

        # Show setup guidance if needed
        if claude_status == :not_configured || gemini_status == :not_configured
            println()
            println("💡 Call MCPRepl.setup() to configure MCP servers interactively")
        end

        println()
        println("🚀 MCP Server running on port $port with $(length(tools)) tools")
        println()  # Add blank line at end of splash
    else
        println("MCP Server running on port $port with $(length(tools)) tools")
    end

    return MCPServer(port, server, tools_dict)
end

function stop_mcp_server(server::MCPServer)
    HTTP.close(server.server)
    println("MCP Server stopped")
end
