using HTTP
using JSON

# Import types and functions from parent module
import ..MCPRepl:
    SecurityConfig, extract_api_key, validate_api_key, get_client_ip, validate_ip

# Server with tool registry
struct MCPServer
    port::Int
    server::HTTP.Server
    tools::Dict{Symbol,MCPTool}           # Symbol-keyed registry
    name_to_id::Dict{String,Symbol}       # String→Symbol lookup for JSON-RPC
end

# Create request handler with access to tools
function create_handler(
    tools::Dict{Symbol,MCPTool},
    name_to_id::Dict{String,Symbol},
    port::Int,
    security_config::Union{SecurityConfig,Nothing} = nothing,
)
    return function handle_request(req::HTTP.Request)
        # Security check - apply to ALL endpoints including vscode-response
        nonce_validated = false  # Track if nonce auth succeeded

        if security_config !== nothing
            # Special handling for vscode-response endpoint with nonce auth
            if req.target == "/vscode-response" && req.method == "POST"
                # Extract the nonce (Bearer token) from Authorization header
                nonce = extract_api_key(req)

                # Parse request body to get request_id
                body = String(req.body)
                request_id = nothing
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)
                catch e
                    # Will fail validation below if can't parse
                end

                # Validate and consume nonce
                if nonce !== nothing && request_id !== nothing
                    if MCPRepl.validate_and_consume_nonce(string(request_id), String(nonce))
                        # Nonce is valid and consumed
                        # Skip all other security checks - nonce auth is sufficient
                        nonce_validated = true
                    else
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict("error" => "Unauthorized: Invalid or expired nonce"),
                            ),
                        )
                    end
                elseif security_config.mode != :lax
                    # No valid nonce, fall back to API key validation for vscode-response
                    if nonce === nothing
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict(
                                    "error" => "Unauthorized: Missing nonce or API key in Authorization header",
                                ),
                            ),
                        )
                    end

                    if !validate_api_key(String(nonce), security_config)
                        return HTTP.Response(
                            401,
                            ["Content-Type" => "application/json"],
                            JSON.json(Dict("error" => "Unauthorized: Invalid API key")),
                        )
                    end

                    # If using API key (not nonce), still need to validate IP
                    client_ip = get_client_ip(req)
                    if !validate_ip(client_ip, security_config)
                        return HTTP.Response(
                            403,
                            ["Content-Type" => "application/json"],
                            JSON.json(
                                Dict(
                                    "error" => "Forbidden: IP address $client_ip not allowed",
                                ),
                            ),
                        )
                    end
                end
            elseif !nonce_validated
                # For non-vscode-response endpoints, use standard API key validation
                # Extract and validate API key
                api_key = extract_api_key(req)
                if api_key === nothing && security_config.mode != :lax
                    return HTTP.Response(
                        401,
                        ["Content-Type" => "application/json"],
                        JSON.json(
                            Dict(
                                "error" => "Unauthorized: Missing API key in Authorization header",
                            ),
                        ),
                    )
                end

                if !validate_api_key(String(something(api_key, "")), security_config)
                    return HTTP.Response(
                        403,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("error" => "Forbidden: Invalid API key")),
                    )
                end

                # Validate IP address
                client_ip = get_client_ip(req)
                if !validate_ip(client_ip, security_config)
                    return HTTP.Response(
                        403,
                        ["Content-Type" => "application/json"],
                        JSON.json(
                            Dict("error" => "Forbidden: IP address $client_ip not allowed"),
                        ),
                    )
                end
            end
        end

        # Parse JSON-RPC request
        body = String(req.body)

        try
            # Handle VS Code response endpoint (for bidirectional communication)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)

                    if request_id === nothing
                        return HTTP.Response(
                            400,
                            ["Content-Type" => "application/json"],
                            JSON.json(Dict("error" => "Missing request_id")),
                        )
                    end

                    result = get(response_data, "result", nothing)
                    error = get(response_data, "error", nothing)

                    # Store the response using MCPRepl function
                    MCPRepl.store_vscode_response(string(request_id), result, error)

                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("status" => "ok")),
                    )
                catch e
                    return HTTP.Response(
                        500,
                        ["Content-Type" => "application/json"],
                        JSON.json(Dict("error" => "Failed to process response: $e")),
                    )
                end
            end

            # Handle AGENTS.md well-known documentation (before JSON parsing)
            # Serve AGENTS.md from project root if it exists
            if req.target == "/.well-known/agents.md" ||
               req.target == "/agents.md" ||
               req.target == "/.well-known/AGENTS.md" ||
               req.target == "/AGENTS.md"
                agents_path = joinpath(pwd(), "AGENTS.md")
                if isfile(agents_path)
                    agents_content = read(agents_path, String)
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "text/markdown; charset=utf-8"],
                        agents_content,
                    )
                else
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "text/plain"],
                        "AGENTS.md not found in project root",
                    )
                end
            end

            # Handle OAuth well-known metadata requests first (before JSON parsing)
            # Only advertise OAuth if security is configured (not in lax mode)
            if req.target == "/.well-known/oauth-authorization-server"
                if security_config !== nothing && security_config.mode != :lax
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
                        JSON.json(oauth_metadata),
                    )
                else
                    # No OAuth in lax mode - return 404
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle dynamic client registration
            # Only support OAuth if security is configured (not in lax mode)
            if req.target == "/oauth/register" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
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
                        JSON.json(registration_response),
                    )
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle authorization endpoint
            if startswith(req.target, "/oauth/authorize")
                if security_config !== nothing && security_config.mode != :lax
                    # For local development, auto-approve all requests
                    uri = HTTP.URI(req.target)
                    query_params = HTTP.queryparams(uri)
                    redirect_uri = get(query_params, "redirect_uri", "")
                    state = get(query_params, "state", "")

                    auth_code = "auth_" * string(rand(UInt64), base = 16)
                    redirect_url = "$redirect_uri?code=$auth_code&state=$state"

                    return HTTP.Response(302, ["Location" => redirect_url], "")
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle token endpoint
            if req.target == "/oauth/token" && req.method == "POST"
                if security_config !== nothing && security_config.mode != :lax
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
                        JSON.json(token_response),
                    )
                else
                    return HTTP.Response(404, ["Content-Type" => "text/plain"], "Not Found")
                end
            end

            # Handle empty body (like GET requests) - only for JSON-RPC endpoints
            # Note: Static file endpoints (AGENTS.md, OAuth metadata) already handled above
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
                    JSON.json(error_response),
                )
            end

            request = JSON.parse(body; dicttype = Dict{String,Any})

            # Check if method field exists
            if !haskey(request, "method")
                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => get(request, "id", 0),
                    "error" => Dict(
                        "code" => -32600,
                        "message" => "Invalid Request - missing method field",
                    ),
                )
                return HTTP.Response(
                    400,
                    ["Content-Type" => "application/json"],
                    JSON.json(error_response),
                )
            end

            # Handle initialization
            if request["method"] == "initialize"
                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
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
                    JSON.json(response),
                )
            end

            # Handle initialized notification
            if request["method"] == "notifications/initialized"
                # This is a notification, no response needed
                return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
            end


            # Handle tool listing
            if request["method"] == "tools/list"
                tool_list = [
                    Dict(
                        "name" => tool.name,
                        "description" => tool.description,
                        "inputSchema" => tool.parameters,
                    ) for tool in values(tools)
                ]

                response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request["id"],
                    "result" => Dict("tools" => tool_list),
                )
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON.json(response),
                )
            end

            # Handle tool calls
            if request["method"] == "tools/call"
                tool_name_str = request["params"]["name"]
                tool_id = get(name_to_id, tool_name_str, nothing)

                if tool_id !== nothing && haskey(tools, tool_id)
                    tool = tools[tool_id]
                    args = get(request["params"], "arguments", Dict())

                    # Non-streaming mode (streaming handled in hybrid_handler)
                    result_text = tool.handler(args)

                    response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "result" => Dict(
                            "content" =>
                                [Dict("type" => "text", "text" => result_text)],
                        ),
                    )
                    return HTTP.Response(
                        200,
                        ["Content-Type" => "application/json"],
                        JSON.json(response),
                    )
                else
                    error_response = Dict(
                        "jsonrpc" => "2.0",
                        "id" => request["id"],
                        "error" => Dict(
                            "code" => -32602,
                            "message" => "Tool not found: $tool_name_str",
                        ),
                    )
                    return HTTP.Response(
                        404,
                        ["Content-Type" => "application/json"],
                        JSON.json(error_response),
                    )
                end
            end

            # Method not found
            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => get(request, "id", 0),
                "error" => Dict("code" => -32601, "message" => "Method not found"),
            )
            return HTTP.Response(
                404,
                ["Content-Type" => "application/json"],
                JSON.json(error_response),
            )

        catch e
            # Internal error - show in REPL and return to client
            printstyled("\nMCP Server error: $e\n", color = :red)

            # Try to get the original request ID for proper JSON-RPC error response
            request_id = 0  # Default to 0 instead of nothing to satisfy JSON-RPC schema
            try
                if !isempty(body)
                    parsed_request = JSON.parse(body; dicttype = Dict{String,Any})
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
                JSON.json(error_response),
            )
        end
    end
end


function start_mcp_server(
    tools::Vector{MCPTool},
    port::Int = 3000;
    verbose::Bool = true,
    security_config::Union{SecurityConfig,Nothing} = nothing,
)
    # Build symbol-keyed registry
    tools_dict = Dict{Symbol,MCPTool}(tool.id => tool for tool in tools)
    # Build string→symbol mapping for JSON-RPC
    name_to_id = Dict{String,Symbol}(tool.name => tool.id for tool in tools)

    # Create a hybrid handler that supports both regular and streaming responses
    function hybrid_handler(http::HTTP.Stream)
        req = http.message

        # CRITICAL: Read the request body FIRST before any response
        # HTTP.jl requires reading the full request before writing responses
        body = String(read(http))

        # Security check - apply to ALL endpoints including vscode-response
        nonce_validated = false  # Track if nonce auth succeeded

        if security_config !== nothing
            # Special handling for vscode-response endpoint with nonce auth
            if req.target == "/vscode-response" && req.method == "POST"
                # Extract the nonce (Bearer token) from Authorization header
                nonce = extract_api_key(req)

                # Parse request body to get request_id
                request_id = nothing
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)
                catch e
                    # Will fail validation below if can't parse
                end

                # Validate and consume nonce
                if nonce !== nothing && request_id !== nothing
                    if MCPRepl.validate_and_consume_nonce(string(request_id), String(nonce))
                        # Nonce is valid and consumed - skip all other security checks
                        nonce_validated = true
                    else
                        # Nonce validation failed
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict("error" => "Unauthorized: Invalid or expired nonce"),
                            ),
                        )
                        return nothing
                    end
                elseif security_config.mode != :lax
                    # No valid nonce, fall back to API key validation for vscode-response
                    if nonce === nothing
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict(
                                    "error" => "Unauthorized: Missing nonce or API key in Authorization header",
                                ),
                            ),
                        )
                        return nothing
                    end

                    if !validate_api_key(String(nonce), security_config)
                        HTTP.setstatus(http, 401)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(Dict("error" => "Unauthorized: Invalid API key")),
                        )
                        return nothing
                    end

                    # If using API key (not nonce), still need to validate IP
                    client_ip = get_client_ip(req)
                    if !validate_ip(client_ip, security_config)
                        HTTP.setstatus(http, 403)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(
                            http,
                            JSON.json(
                                Dict(
                                    "error" => "Forbidden: IP address $client_ip not allowed",
                                ),
                            ),
                        )
                        return nothing
                    end
                end
            elseif !nonce_validated
                # For non-vscode-response endpoints, use standard API key validation
                api_key = extract_api_key(req)
                if api_key === nothing && security_config.mode != :lax
                    HTTP.setstatus(http, 401)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict(
                                "error" => "Unauthorized: Missing API key in Authorization header",
                            ),
                        ),
                    )
                    return nothing
                end

                if !validate_api_key(String(something(api_key, "")), security_config)
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("error" => "Forbidden: Invalid API key")))
                    return nothing
                end

                # Validate IP address
                client_ip = get_client_ip(req)
                if !validate_ip(client_ip, security_config)
                    HTTP.setstatus(http, 403)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(
                            Dict("error" => "Forbidden: IP address $client_ip not allowed"),
                        ),
                    )
                    return nothing
                end
            end
        end

        try
            # Handle AGENTS.md endpoint (can have empty body for GET requests)
            if req.target == "/.well-known/agents.md" ||
               req.target == "/agents.md" ||
               req.target == "/.well-known/AGENTS.md" ||
               req.target == "/AGENTS.md"
                agents_path = joinpath(pwd(), "AGENTS.md")
                if isfile(agents_path)
                    agents_content = read(agents_path, String)
                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "text/markdown; charset=utf-8")
                    HTTP.startwrite(http)
                    write(http, agents_content)
                    return nothing
                else
                    HTTP.setstatus(http, 404)
                    HTTP.setheader(http, "Content-Type" => "text/plain")
                    HTTP.startwrite(http)
                    write(http, "AGENTS.md not found in project root")
                    return nothing
                end
            end

            # Handle VS Code response endpoint FIRST (before any JSON parsing)
            if req.target == "/vscode-response" && req.method == "POST"
                try
                    response_data = JSON.parse(body; dicttype = Dict{String,Any})
                    request_id = get(response_data, "request_id", nothing)

                    if request_id === nothing
                        HTTP.setstatus(http, 400)
                        HTTP.setheader(http, "Content-Type" => "application/json")
                        HTTP.startwrite(http)
                        write(http, JSON.json(Dict("error" => "Missing request_id")))
                        return nothing
                    end

                    result = get(response_data, "result", nothing)
                    error = get(response_data, "error", nothing)

                    # Store the response
                    MCPRepl.store_vscode_response(string(request_id), result, error)

                    HTTP.setstatus(http, 200)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, JSON.json(Dict("status" => "ok")))
                    return nothing
                catch e
                    HTTP.setstatus(http, 500)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(
                        http,
                        JSON.json(Dict("error" => "Failed to process response: $e")),
                    )
                    return nothing
                end
            end

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
                write(http, JSON.json(error_response))
                return nothing
            end

            # All requests go to create_handler
            # create_handler handles:
            # - Security checks (already done above, but also in create_handler for direct calls)
            # - OAuth endpoints
            # - VS Code response endpoint
            # - initialize, tools/list, and tools/call
            req_with_body = HTTP.Request(req.method, req.target, req.headers, body)
            handler = create_handler(tools_dict, name_to_id, port, security_config)
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
                parsed = JSON.parse(body; dicttype = Dict{String,Any})
                get(parsed, :id, 0)
            catch
                0
            end

            error_response = Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict("code" => -32603, "message" => "Internal error: $e"),
            )
            write(http, JSON.json(error_response))
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

    return MCPServer(port, server, tools_dict, name_to_id)
end

function stop_mcp_server(server::MCPServer)
    HTTP.close(server.server)
    println("MCP Server stopped")
end
