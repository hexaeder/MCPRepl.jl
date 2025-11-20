goto_definition_tool = @mcp_tool(
    :lsp_goto_definition,
    "Find the definition of a symbol using Julia LSP. Navigates to the source code location where a given symbol is defined.",
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
    "Find all references to a symbol using Julia LSP. Lists all locations in the workspace where a given symbol is referenced.",
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
    "List all symbols in a file using Julia LSP. Returns a list of symbols defined within a specific document, such as functions, classes, and variables.",
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
    "Search for symbols across the workspace using Julia LSP. Allows searching for symbols by name across the entire workspace.",
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
    "Rename a symbol across the workspace using Julia LSP. Renames a symbol (e.g., variable, function) and updates all references to it throughout the workspace.",
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
    "Get available code actions and quick fixes using Julia LSP. Retrieves a list of available code actions, such as quick fixes and refactorings, at a given position in a file.",
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

# ============================================================================
# MCP Tools for LSP Operations
# ============================================================================

function create_lsp_tools()
    result = [
        goto_definition_tool,
        find_references_tool,
        document_symbols_tool,
        workspace_symbols_tool,
        rename_tool,
        code_actions_tool,
    ]
    return result
end