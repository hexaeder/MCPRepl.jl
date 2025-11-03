# ============================================================================
# LSP (Language Server Protocol) Integration
# ============================================================================
#
# This module provides tools for interacting with Julia's LanguageServer.jl
# via the VS Code Julia extension's LSP client.
#
# Communication Strategy:
# We use VS Code's executeCommand to send custom LSP requests to the Julia
# extension's language client, which forwards them to LanguageServer.jl.
# Results come back via the bidirectional communication mechanism.

"""
    file_uri(path::AbstractString) -> String

Convert a file path to a `file://` URI as expected by LSP.
Handles proper escaping and platform differences.
"""
function file_uri(path::AbstractString)
    abs_path = abspath(path)
    # Ensure forward slashes for URI
    uri_path = replace(abs_path, "\\" => "/")
    # Add leading slash for absolute paths if not present
    if !startswith(uri_path, "/")
        uri_path = "/" * uri_path
    end
    return "file://" * uri_path
end

"""
    uri_to_path(uri) -> String

Convert a `file://` URI or VS Code Uri object to a file system path.
Handles both string URIs and Dict objects from VS Code.
"""
function uri_to_path(uri)
    # Handle Dict from VS Code (with "path" key)
    if uri isa Dict
        uri = get(uri, "path", get(uri, "uri", ""))
    end

    # Handle string URI
    if uri isa AbstractString
        if startswith(uri, "file://")
            path = uri[8:end]  # Remove "file://"
            # Handle Windows paths
            if Sys.iswindows() && match(r"^/[A-Za-z]:", path) !== nothing
                path = path[2:end]  # Remove leading slash before drive letter
            end
            return path
        end
        return uri
    end

    return string(uri)
end

"""
    LSPPosition(line::Int, character::Int)

LSP position - 0-indexed line and character.
Note: Julia uses 1-indexed, LSP uses 0-indexed.
"""
struct LSPPosition
    line::Int         # 0-indexed
    character::Int    # 0-indexed
end

# Convert from Julia 1-indexed to LSP 0-indexed
LSPPosition(julia_line::Int, julia_col::Int, ::Val{:julia}) =
    LSPPosition(julia_line - 1, julia_col - 1)

"""
    LSPRange(start::LSPPosition, end_pos::LSPPosition)

LSP range with start and end positions.
"""
struct LSPRange
    start::LSPPosition
    end_pos::LSPPosition  # 'end' is reserved in Julia
end

"""
    LSPLocation(uri::String, range::LSPRange)

LSP location - a range in a specific document.
"""
struct LSPLocation
    uri::String
    range::LSPRange
end

"""
    send_lsp_request(method::String, params::Dict; timeout::Float64=10.0) -> Dict

Send an LSP request to LanguageServer.jl via VS Code's language client.
Uses the bidirectional communication mechanism to get responses.

# Arguments
- `method`: LSP method name (e.g., "textDocument/definition")
- `params`: LSP request parameters as a Dict
- `timeout`: Maximum time to wait for response (default: 10 seconds)

# Returns
- Dict with LSP response or error information
"""
function send_lsp_request(method::String, params::Dict; timeout::Float64 = 10.0)
    # Generate unique request ID
    request_id = string(rand(UInt64), base = 16)

    try
        # Build the LSP request payload
        lsp_request = Dict(
            "jsonrpc" => "2.0",
            "id" => request_id,
            "method" => method,
            "params" => params,
        )

        # Use the julia.executeLSPRequest command (if it exists)
        # Otherwise, we'll use vscode.executeDefinitionProvider and similar
        # built-in commands that are LSP-aware

        # For now, use the built-in VS Code LSP commands which are more reliable
        return execute_builtin_lsp_command(method, params, timeout)

    catch e
        return Dict("error" => "Failed to send LSP request: $e", "method" => method)
    end
end

"""
    execute_builtin_lsp_command(method::String, params::Dict, timeout::Float64) -> Dict

Execute VS Code's built-in LSP-aware commands.
These are more reliable than trying to communicate directly with the language server.
"""
function execute_builtin_lsp_command(method::String, params::Dict, timeout::Float64)
    # Map LSP methods to VS Code commands
    command_map = Dict(
        "textDocument/definition" => "vscode.executeDefinitionProvider",
        "textDocument/references" => "vscode.executeReferenceProvider",
        "textDocument/hover" => "vscode.executeHoverProvider",
        "textDocument/documentSymbol" => "vscode.executeDocumentSymbolProvider",
        "workspace/symbol" => "vscode.executeWorkspaceSymbolProvider",
        "textDocument/signatureHelp" => "vscode.executeSignatureHelpProvider",
        "textDocument/rename" => "vscode.executeDocumentRenameProvider",
        "textDocument/documentHighlight" => "vscode.executeDocumentHighlights",
    )

    vscode_command = get(command_map, method, nothing)
    if vscode_command === nothing
        return Dict("error" => "Unsupported LSP method: $method")
    end

    # Build VS Code command arguments based on LSP params
    args = build_vscode_command_args(method, params)

    # Execute via the existing execute_vscode_command infrastructure
    result = execute_vscode_command_with_result(vscode_command, args, timeout)

    return result
end

"""
    build_vscode_command_args(method::String, params::Dict) -> Vector

Build VS Code command arguments from LSP parameters.
"""
function build_vscode_command_args(method::String, params::Dict)
    args = []

    if haskey(params, "textDocument")
        # Pass the URI string - VS Code commands should handle conversion
        uri = get(params["textDocument"], "uri", "")
        push!(args, uri)
    end

    if haskey(params, "position")
        # LSP positions are 0-indexed, pass them as-is
        pos = params["position"]
        push!(args, pos)
    end

    # Special handling for rename - newName is the third parameter
    if method == "textDocument/rename" && haskey(params, "newName")
        push!(args, params["newName"])
    end

    # Special handling for workspace/symbol
    if method == "workspace/symbol" && haskey(params, "query")
        args = [params["query"]]
    end

    return args
end

"""
    execute_vscode_command_with_result(command::String, args::Vector, timeout::Float64) -> Dict

Execute a VS Code command and wait for the result using bidirectional communication.
"""
function execute_vscode_command_with_result(command::String, args::Vector, timeout::Float64)
    # Generate unique request ID for tracking
    request_id = string(rand(UInt64), base = 16)

    # Generate a single-use nonce for this specific request
    nonce = generate_nonce()
    store_nonce(request_id, nonce)

    # Get current MCP server port
    server_port = SERVER[] !== nothing ? SERVER[].port : 3000

    # Build the VS Code URI with request_id and nonce
    args_json = isempty(args) ? nothing : JSON.json(args)
    uri = build_vscode_uri(
        command;
        args = args_json === nothing ? nothing : HTTP.URIs.escapeuri(args_json),
        request_id = request_id,
        mcp_port = server_port,
        nonce = nonce,
    )

    # Trigger the command
    trigger_vscode_uri(uri)

    # Wait for response
    try
        result, error = retrieve_vscode_response(request_id; timeout = timeout)

        if error !== nothing
            return Dict("error" => error)
        end

        return Dict("result" => result)
    catch e
        if occursin("timed out", string(e))
            return Dict("error" => "LSP request timed out after $(timeout)s")
        else
            return Dict("error" => "Error retrieving LSP result: $e")
        end
    end
end

"""
    format_location(location) -> String

Format a single location result for display.
"""
function format_location(location)
    # JSON.parse returns Dict with string keys
    uri = get(location, "uri", "")
    range = get(location, "range", nothing)

    if range !== nothing
        # Handle nested start object - check if it's iterable (array) first
        if range isa AbstractVector && length(range) >= 1
            start_obj = range[1]
        else
            start_obj = get(range, "start", nothing)
        end

        if start_obj !== nothing
            start_line = get(start_obj, "line", 0)
            start_char = get(start_obj, "character", 0)

            # Convert 0-indexed LSP to 1-indexed Julia
            file_path = uri_to_path(uri)
            return "$(file_path):$(start_line + 1):$(start_char + 1)"
        end
    end

    return string(location)
end

"""
    format_locations(locations) -> String

Format multiple location results for display.
"""
function format_locations(locations)
    if isnothing(locations) || (locations isa Vector && isempty(locations))
        return "No results found"
    end

    if !(locations isa Vector)
        locations = [locations]
    end

    result = "Found $(length(locations)) location(s):\n"
    for (i, loc) in enumerate(locations)
        result *= "  $i. $(format_location(loc))\n"
    end

    return result
end

"""
    format_hover_info(hover_result) -> String

Format hover information for display.
"""
function format_hover_info(hover_result)
    # JSON.parse returns Dict with string keys
    contents = get(hover_result, "contents", nothing)

    if contents !== nothing
        # Contents can be a string, MarkedString, or array
        if contents isa String
            return contents
        elseif contents isa Dict && haskey(contents, "value")
            return contents["value"]
        elseif contents isa AbstractVector
            return join(
                [item isa String ? item : get(item, "value", "") for item in contents],
                "\n\n",
            )
        end
    end

    return "No hover information available"
end

"""
    format_symbols(symbols) -> String

Format document or workspace symbols for display.
"""
function format_symbols(symbols)
    if isnothing(symbols) || (symbols isa Vector && isempty(symbols))
        return "No symbols found"
    end

    if !(symbols isa Vector)
        symbols = [symbols]
    end

    result = "Found $(length(symbols)) symbol(s):\n"
    for (i, sym) in enumerate(symbols)
        # JSON.parse returns Dict with string keys
        name = get(sym, "name", "")
        kind = get(sym, "kind", 0)
        location = get(sym, "location", nothing)

        # Convert kind string to number if needed
        if kind isa String
            # VS Code returns kind as string sometimes (e.g., "Function")
            # Map common ones back to numbers for symbol_kind_to_string
            kind_map = Dict(
                "Function" => 12,
                "Method" => 6,
                "Class" => 5,
                "Struct" => 23,
                "Variable" => 13,
                "Constant" => 14,
                "Module" => 2,
                "Package" => 4,
            )
            kind = get(kind_map, kind, 0)
        end

        kind_str = kind isa Int ? symbol_kind_to_string(kind) : string(kind)

        if location !== nothing
            loc_str = format_location(location)
            result *= "  $i. [$kind_str] $name @ $loc_str\n"
        else
            result *= "  $i. [$kind_str] $name\n"
        end
    end

    return result
end

"""
    symbol_kind_to_string(kind::Int) -> String

Convert LSP SymbolKind enum to string.
"""
function symbol_kind_to_string(kind::Int)
    kinds = Dict(
        1 => "File",
        2 => "Module",
        3 => "Namespace",
        4 => "Package",
        5 => "Class",
        6 => "Method",
        7 => "Property",
        8 => "Field",
        9 => "Constructor",
        10 => "Enum",
        11 => "Interface",
        12 => "Function",
        13 => "Variable",
        14 => "Constant",
        15 => "String",
        16 => "Number",
        17 => "Boolean",
        18 => "Array",
        19 => "Object",
        20 => "Key",
        21 => "Null",
        22 => "EnumMember",
        23 => "Struct",
        24 => "Event",
        25 => "Operator",
        26 => "TypeParameter",
    )
    return get(kinds, kind, "Unknown")
end

# ============================================================================
# MCP Tools for LSP Operations
# ============================================================================

"""
Create MCP tools for LSP operations that can be added to the server.
"""
function create_lsp_tools()
    goto_definition_tool = @mcp_tool(
        :lsp_goto_definition,
        "Find the definition of a symbol using Julia Language Server Protocol. Navigate to where functions, types, variables, or modules are defined in the codebase.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "file_path" => Dict(
                    "type" => "string",
                    "description" => "Absolute path to the file",
                ),
                "line" => Dict(
                    "type" => "integer",
                    "description" => "Line number (1-indexed)",
                ),
                "column" => Dict(
                    "type" => "integer",
                    "description" => "Column number (1-indexed)",
                ),
            ),
            "required" => ["file_path", "line", "column"],
        ),
        function (args)
            try
                file_path = get(args, "file_path", "")
                line = get(args, "line", 1)
                column = get(args, "column", 1)

                if isempty(file_path)
                    return "Error: file_path is required"
                end

                if !isfile(file_path)
                    return "Error: File not found: $file_path"
                end

                # Convert to LSP format (0-indexed)
                lsp_params = Dict(
                    "textDocument" => Dict("uri" => file_uri(file_path)),
                    "position" => Dict("line" => line - 1, "character" => column - 1),
                )

                # Send LSP request
                response = send_lsp_request("textDocument/definition", lsp_params)

                if haskey(response, "error")
                    return "Error: $(response["error"])"
                end

                result = get(response, "result", nothing)
                return format_locations(result)

            catch e
                return "Error finding definition: $e"
            end
        end
    )

    find_references_tool = @mcp_tool(
        :lsp_find_references,
        "Find all references to a symbol using Julia Language Server Protocol. Locate all usages of functions, types, variables, or modules throughout the codebase.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "file_path" => Dict(
                    "type" => "string",
                    "description" => "Absolute path to the file",
                ),
                "line" => Dict(
                    "type" => "integer",
                    "description" => "Line number (1-indexed)",
                ),
                "column" => Dict(
                    "type" => "integer",
                    "description" => "Column number (1-indexed)",
                ),
                "include_declaration" => Dict(
                    "type" => "boolean",
                    "description" => "Include declaration (default: true)",
                ),
            ),
            "required" => ["file_path", "line", "column"],
        ),
        function (args)
            try
                file_path = get(args, "file_path", "")
                line = get(args, "line", 1)
                column = get(args, "column", 1)
                include_decl = get(args, "include_declaration", true)

                if isempty(file_path)
                    return "Error: file_path is required"
                end

                if !isfile(file_path)
                    return "Error: File not found: $file_path"
                end

                # Convert to LSP format
                lsp_params = Dict(
                    "textDocument" => Dict("uri" => file_uri(file_path)),
                    "position" => Dict("line" => line - 1, "character" => column - 1),
                    "context" => Dict("includeDeclaration" => include_decl),
                )

                # Send LSP request
                response = send_lsp_request("textDocument/references", lsp_params)

                if haskey(response, "error")
                    return "Error: $(response["error"])"
                end

                result = get(response, "result", nothing)
                return format_locations(result)

            catch e
                return "Error finding references: $e"
            end
        end
    )

    document_symbols_tool = @mcp_tool(
        :lsp_document_symbols,
        "List all symbols in a file using Julia Language Server Protocol. Get an outline of functions, types, constants, and other definitions in a Julia source file.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "file_path" => Dict(
                    "type" => "string",
                    "description" => "Absolute path to the file",
                ),
            ),
            "required" => ["file_path"],
        ),
        function (args)
            try
                file_path = get(args, "file_path", "")

                if isempty(file_path)
                    return "Error: file_path is required"
                end

                if !isfile(file_path)
                    return "Error: File not found: $file_path"
                end

                # Convert to LSP format
                lsp_params = Dict("textDocument" => Dict("uri" => file_uri(file_path)))

                # Send LSP request
                response = send_lsp_request("textDocument/documentSymbol", lsp_params)

                if haskey(response, "error")
                    return "Error: $(response["error"])"
                end

                result = get(response, "result", nothing)
                return format_symbols(result)

            catch e
                return "Error listing symbols: $e"
            end
        end
    )

    workspace_symbols_tool = @mcp_tool(
        :lsp_workspace_symbols,
        "Search for symbols across the workspace using Julia Language Server Protocol. Find functions, types, and other definitions by name throughout the entire project.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "query" => Dict(
                    "type" => "string",
                    "description" => "Search query for symbol names",
                ),
            ),
            "required" => ["query"],
        ),
        function (args)
            try
                query = get(args, "query", "")

                if isempty(query)
                    return "Error: query is required"
                end

                # Convert to LSP format
                lsp_params = Dict("query" => query)

                # Send LSP request
                response = send_lsp_request("workspace/symbol", lsp_params)

                if haskey(response, "error")
                    return "Error: $(response["error"])"
                end

                result = get(response, "result", nothing)
                return format_symbols(result)

            catch e
                return "Error searching symbols: $e"
            end
        end
    )

    # Rename symbol tool
    rename_tool = @mcp_tool(
        :lsp_rename,
        "Rename a symbol across the workspace using Julia Language Server Protocol. Safely rename functions, types, variables, or modules with automatic updates to all references.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "file_path" => Dict(
                    "type" => "string",
                    "description" => "Absolute path to the file",
                ),
                "line" => Dict(
                    "type" => "integer",
                    "description" => "Line number (1-indexed)",
                ),
                "column" => Dict(
                    "type" => "integer",
                    "description" => "Column number (1-indexed)",
                ),
                "new_name" => Dict(
                    "type" => "string",
                    "description" => "New name for the symbol",
                ),
            ),
            "required" => ["file_path", "line", "column", "new_name"],
        ),
        function (args)
            try
                file_path = get(args, "file_path", "")
                line = get(args, "line", 1)
                column = get(args, "column", 1)
                new_name = get(args, "new_name", "")

                if isempty(file_path) || isempty(new_name)
                    return "Error: file_path and new_name are required"
                end

                if !isfile(file_path)
                    return "Error: File not found: $file_path"
                end

                # Convert to LSP format
                lsp_params = Dict(
                    "textDocument" => Dict("uri" => file_uri(file_path)),
                    "position" => Dict("line" => line - 1, "character" => column - 1),
                    "newName" => new_name,
                )

                # Send LSP request
                response = send_lsp_request("textDocument/rename", lsp_params)

                if haskey(response, "error")
                    return "Error: $(response["error"])"
                end

                result = get(response, "result", nothing)
                if result === nothing
                    return "No rename edits generated. Symbol may not be renameable."
                end

                # Format workspace edit
                return format_workspace_edit(result)

            catch e
                return "Error renaming symbol: $e"
            end
        end
    )

    # Code actions tool
    code_actions_tool = @mcp_tool(
        :lsp_code_actions,
        "Get available code actions and quick fixes using Julia Language Server Protocol. Discover refactoring options, auto-fixes, and code improvements for the selected code range.",
        Dict(
            "type" => "object",
            "properties" => Dict(
                "file_path" => Dict(
                    "type" => "string",
                    "description" => "Absolute path to the file",
                ),
                "start_line" => Dict(
                    "type" => "integer",
                    "description" => "Start line number (1-indexed)",
                ),
                "start_column" => Dict(
                    "type" => "integer",
                    "description" => "Start column number (1-indexed)",
                ),
                "end_line" => Dict(
                    "type" => "integer",
                    "description" => "End line number (1-indexed, optional)",
                ),
                "end_column" => Dict(
                    "type" => "integer",
                    "description" => "End column number (1-indexed, optional)",
                ),
                "kind" => Dict(
                    "type" => "string",
                    "description" => "Filter by action kind (optional)",
                ),
            ),
            "required" => ["file_path", "start_line", "start_column"],
        ),
        function (args)
            try
                file_path = get(args, "file_path", "")
                start_line = get(args, "start_line", 1)
                start_column = get(args, "start_column", 1)
                end_line = get(args, "end_line", start_line)
                end_column = get(args, "end_column", start_column)
                kind = get(args, "kind", nothing)

                if isempty(file_path)
                    return "Error: file_path is required"
                end

                if !isfile(file_path)
                    return "Error: File not found: $file_path"
                end

                # Convert to LSP format
                uri = file_uri(file_path)
                lsp_params = [
                    uri,
                    Dict(
                        "start" => Dict(
                            "line" => start_line - 1,
                            "character" => start_column - 1,
                        ),
                        "end" => Dict(
                            "line" => end_line - 1,
                            "character" => end_column - 1,
                        ),
                    ),
                ]

                if kind !== nothing
                    push!(lsp_params, kind)
                end

                # Use execute_vscode_command_with_result directly
                result = execute_vscode_command_with_result(
                    "vscode.executeCodeActionProvider",
                    lsp_params,
                    10.0,
                )

                if haskey(result, "error")
                    return "Error: $(result["error"])"
                end

                actions = get(result, "result", nothing)
                return format_code_actions(actions)

            catch e
                return "Error getting code actions: $e"
            end
        end
    )

    return [
        goto_definition_tool,
        find_references_tool,
        document_symbols_tool,
        workspace_symbols_tool,
        rename_tool,
        code_actions_tool,
    ]
end

# ============================================================================
# Additional Formatting Functions
# ============================================================================

"""
    format_workspace_edit(edit) -> String

Format a workspace edit showing all file changes.
Handles multiple formats:
1. Standard LSP: changes dict with uri keys
2. Standard LSP: documentChanges array
3. VS Code custom: nested array format
"""
function format_workspace_edit(edit)
    if edit === nothing
        return "No rename edits available. The symbol may not be renameable."
    end

    # Handle empty array - means no edits (symbol can't be renamed)
    if edit isa Vector && isempty(edit)
        return "No rename edits available. The symbol may not be renameable (e.g., module names, keywords, built-in types)."
    end

    # Handle VS Code custom format: [[uri_dict, [edits]]]
    if edit isa Vector && !isempty(edit)
        # Check if it's the nested array format from VS Code
        first_elem = first(edit)
        if first_elem isa Vector && length(first_elem) >= 2
            # VS Code format: [[uri_dict, [edits]]]
            return format_vscode_rename_result(edit)
        elseif first_elem isa Vector && length(first_elem) < 2
            # Malformed VS Code format - not enough elements
            return "No rename edits available. The symbol may not be renameable."
        end
        # If first element is a Dict, it might be standard LSP format
        if first_elem isa Dict
            edit = first_elem
        else
            # Unknown format
            return "Unexpected workspace edit format. The symbol may not be renameable."
        end
    end

    if !(edit isa Dict)
        return "No rename edits available. Unexpected format: $(typeof(edit))"
    end

    if isempty(edit)
        return "No edits to apply"
    end

    # Try to get changes - might be under "changes" or "documentChanges"
    changes = get(edit, "changes", nothing)

    if changes === nothing || (changes isa Dict && isempty(changes))
        # Try documentChanges format
        doc_changes = get(edit, "documentChanges", nothing)
        if doc_changes !== nothing && !isempty(doc_changes)
            return format_document_changes(doc_changes)
        end
        return "No file changes"
    end

    if !(changes isa Dict)
        return "Unexpected changes format: $(typeof(changes))"
    end

    result = "Workspace edit would modify $(length(changes)) file(s):\n"
    for (uri, text_edits) in changes
        file_path = uri_to_path(uri)

        if !(text_edits isa Vector)
            continue
        end

        result *= "\n📄 $file_path: $(length(text_edits)) edit(s)\n"
        for (i, text_edit) in enumerate(text_edits)
            if !(text_edit isa Dict)
                continue
            end

            range = get(text_edit, "range", nothing)
            new_text = get(text_edit, "newText", "")
            if range !== nothing && range isa Dict
                start = get(range, "start", nothing)
                if start !== nothing && start isa Dict
                    line = get(start, "line", 0) + 1
                    result *= "  $i. Line $line: \"$new_text\"\n"
                end
            end
        end
    end

    return result
end

"""
    format_vscode_rename_result(edit_array) -> String

Format VS Code custom rename result format with nested arrays.
"""
function format_vscode_rename_result(edit_array)
    if !(edit_array isa Vector) || isempty(edit_array)
        return "No edits to apply"
    end

    result = "Workspace edit would modify file(s):\n"

    for item in edit_array
        if !(item isa Vector) || length(item) < 2
            result *= "  [Skipped item: $(typeof(item)), length=$(item isa Vector ? length(item) : "N/A")]\n"
            continue
        end

        # First element is the URI info
        uri_info = item[1]
        # Second element is the edits array
        edits = item[2]

        # Extract file path from URI info
        file_path = "unknown"
        if uri_info isa Dict
            # Try different URI fields
            if haskey(uri_info, "fsPath")
                file_path = uri_info["fsPath"]
            elseif haskey(uri_info, "path")
                file_path = uri_info["path"]
            elseif haskey(uri_info, "external")
                file_path = uri_to_path(uri_info["external"])
            end
        end

        if !(edits isa Vector)
            continue
        end

        result *= "\n📄 $file_path: $(length(edits)) edit(s)\n"

        for (i, text_edit) in enumerate(edits)
            if !(text_edit isa Dict)
                continue
            end

            range = get(text_edit, "range", nothing)
            new_text = get(text_edit, "newText", "")

            if range isa Vector && length(range) >= 2
                # Range is [start_dict, end_dict]
                start = range[1]
                if start isa Dict
                    line = get(start, "line", 0) + 1
                    char = get(start, "character", 0)
                    result *= "  $i. Line $line, Col $char: \"$new_text\"\n"
                end
            elseif range isa Dict
                # Standard format
                start = get(range, "start", nothing)
                if start !== nothing && start isa Dict
                    line = get(start, "line", 0) + 1
                    char = get(start, "character", 0)
                    result *= "  $i. Line $line, Col $char: \"$new_text\"\n"
                end
            end
        end
    end

    return result
end

"""
    format_document_changes(doc_changes) -> String

Format documentChanges array from WorkspaceEdit.
"""
function format_document_changes(doc_changes)
    if !(doc_changes isa Vector) || isempty(doc_changes)
        return "No document changes"
    end

    result = "Workspace edit would modify $(length(doc_changes)) document(s):\n"
    for (i, change) in enumerate(doc_changes)
        if !(change isa Dict)
            continue
        end

        text_doc = get(change, "textDocument", nothing)
        edits = get(change, "edits", [])

        if text_doc !== nothing && text_doc isa Dict
            uri = get(text_doc, "uri", "unknown")
            file_path = uri_to_path(uri)
            result *= "\n📄 $file_path: $(length(edits)) edit(s)\n"

            for (j, edit) in enumerate(edits)
                if !(edit isa Dict)
                    continue
                end

                range = get(edit, "range", nothing)
                new_text = get(edit, "newText", "")
                if range !== nothing && range isa Dict
                    start = get(range, "start", nothing)
                    if start !== nothing && start isa Dict
                        line = get(start, "line", 0) + 1
                        result *= "  $j. Line $line: \"$new_text\"\n"
                    end
                end
            end
        end
    end

    return result
end

"""
    format_code_actions(actions) -> String

Format code actions for display.
"""
function format_code_actions(actions)
    if actions === nothing || (actions isa Vector && isempty(actions))
        return "No code actions available"
    end

    if !(actions isa Vector)
        actions = [actions]
    end

    result = "Found $(length(actions)) code action(s):\n"
    for (i, action) in enumerate(actions)
        title = get(action, "title", "Untitled action")
        kind = get(action, "kind", "unknown")
        result *= "  $i. [$kind] $title\n"
    end

    return result
end

"""
    format_highlights(highlights) -> String

Format document highlights for display.
"""
function format_highlights(highlights)
    if highlights === nothing || (highlights isa Vector && isempty(highlights))
        return "No highlights found"
    end

    if !(highlights isa Vector)
        highlights = [highlights]
    end

    result = "Found $(length(highlights)) occurrence(s):\n"
    for (i, highlight) in enumerate(highlights)
        range = get(highlight, "range", nothing)
        kind = get(highlight, "kind", 1)  # 1=text, 2=read, 3=write
        kind_str = kind == 2 ? "read" : kind == 3 ? "write" : "text"

        if range !== nothing
            start = get(range, "start", Dict())
            line = get(start, "line", 0) + 1
            char = get(start, "character", 0) + 1
            result *= "  $i. [$kind_str] Line $line, Col $char\n"
        end
    end

    return result
end

"""
    format_completions(completions) -> String

Format completion items for display.
"""
function format_completions(completions)
    # Handle CompletionList or array of CompletionItems
    items = if completions isa Dict && haskey(completions, "items")
        get(completions, "items", [])
    elseif completions isa Vector
        completions
    else
        []
    end

    if isempty(items)
        return "No completions available"
    end

    result = "Found $(length(items)) completion(s):\n"
    for (i, item) in enumerate(items[1:min(20, length(items))])  # Limit to 20
        label = get(item, "label", "")
        kind = get(item, "kind", 0)
        detail = get(item, "detail", "")

        kind_str = completion_kind_to_string(kind)
        result *= "  $i. [$kind_str] $label"
        if !isempty(detail)
            result *= " - $detail"
        end
        result *= "\n"
    end

    if length(items) > 20
        result *= "  ... and $(length(items) - 20) more\n"
    end

    return result
end

"""
    completion_kind_to_string(kind::Int) -> String

Convert LSP CompletionItemKind to string.
"""
function completion_kind_to_string(kind::Int)
    kinds = Dict(
        1 => "Text",
        2 => "Method",
        3 => "Function",
        4 => "Constructor",
        5 => "Field",
        6 => "Variable",
        7 => "Class",
        8 => "Interface",
        9 => "Module",
        10 => "Property",
        11 => "Unit",
        12 => "Value",
        13 => "Enum",
        14 => "Keyword",
        15 => "Snippet",
        16 => "Color",
        17 => "File",
        18 => "Reference",
        19 => "Folder",
        20 => "EnumMember",
        21 => "Constant",
        22 => "Struct",
        23 => "Event",
        24 => "Operator",
        25 => "TypeParameter",
    )
    return get(kinds, kind, "Unknown")
end

"""
    format_signature_help(sig_help) -> String

Format signature help for display.
"""
function format_signature_help(sig_help)
    if sig_help === nothing || (sig_help isa Dict && isempty(sig_help))
        return "No signature help available"
    end

    signatures = get(sig_help, "signatures", [])
    if isempty(signatures)
        return "No signatures available"
    end

    active_sig = get(sig_help, "activeSignature", 0)
    active_param = get(sig_help, "activeParameter", nothing)

    result = "Function signatures:\n"
    for (i, sig) in enumerate(signatures)
        label = get(sig, "label", "")
        doc = get(sig, "documentation", nothing)

        prefix = i == active_sig + 1 ? "▶ " : "  "
        result *= "$prefix$i. $label\n"

        if doc !== nothing
            doc_str = doc isa String ? doc : get(doc, "value", "")
            if !isempty(doc_str)
                result *= "     $(doc_str)\n"
            end
        end
    end

    if active_param !== nothing
        result *= "\nActive parameter: $active_param\n"
    end

    return result
end
