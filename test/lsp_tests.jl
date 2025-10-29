using Test
using MCPRepl
using MCPRepl: MCPTool

@testset "LSP Integration Tests" begin

    @testset "LSP Tool Creation" begin
        # Verify all tools are created
        tools = create_lsp_tools()
        @test length(tools) == 8  # Reduced from 12 to 8 (removed GUI-focused tools)

        tool_names = [tool.name for tool in tools]
        # Essential navigation and refactoring tools
        @test "lsp_goto_definition" in tool_names
        @test "lsp_find_references" in tool_names
        @test "lsp_document_symbols" in tool_names
        @test "lsp_workspace_symbols" in tool_names
        # Refactoring and formatting tools
        @test "lsp_rename" in tool_names
        @test "lsp_code_actions" in tool_names
        @test "lsp_format_document" in tool_names
        @test "lsp_format_range" in tool_names

        # Verify tool structure
        for tool in tools
            @test haskey(tool.parameters, "type")
            @test haskey(tool.parameters, "properties")
            @test haskey(tool.parameters, "required")
            @test !isempty(tool.description)
            @test tool isa MCPTool
        end
    end

    @testset "Tool Parameter Validation" begin
        tools = create_lsp_tools()

        # Check goto_definition parameters
        goto_def = filter(t -> t.name == "lsp_goto_definition", tools)[1]
        @test haskey(goto_def.parameters["properties"], "file_path")
        @test haskey(goto_def.parameters["properties"], "line")
        @test haskey(goto_def.parameters["properties"], "column")
        @test "file_path" in goto_def.parameters["required"]
        @test "line" in goto_def.parameters["required"]
        @test "column" in goto_def.parameters["required"]

        # Check find_references parameters
        find_refs = filter(t -> t.name == "lsp_find_references", tools)[1]
        @test haskey(find_refs.parameters["properties"], "file_path")
        @test haskey(find_refs.parameters["properties"], "line")
        @test haskey(find_refs.parameters["properties"], "column")
        @test haskey(find_refs.parameters["properties"], "include_declaration")

        # Check hover_info parameters
        hover = filter(t -> t.name == "lsp_hover_info", tools)[1]
        @test haskey(hover.parameters["properties"], "file_path")
        @test haskey(hover.parameters["properties"], "line")
        @test haskey(hover.parameters["properties"], "column")

        # Check document_symbols parameters
        doc_syms = filter(t -> t.name == "lsp_document_symbols", tools)[1]
        @test haskey(doc_syms.parameters["properties"], "file_path")
        @test "file_path" in doc_syms.parameters["required"]

        # Check workspace_symbols parameters
        ws_syms = filter(t -> t.name == "lsp_workspace_symbols", tools)[1]
        @test haskey(ws_syms.parameters["properties"], "query")
        @test "query" in ws_syms.parameters["required"]
    end

    @testset "Tool Error Handling" begin
        tools = create_lsp_tools()

        # Test goto_definition with missing file
        goto_def = filter(t -> t.name == "lsp_goto_definition", tools)[1]
        result = goto_def.handler(Dict("file_path" => "", "line" => 1, "column" => 1))
        @test contains(result, "Error")

        # Test with non-existent file
        result2 = goto_def.handler(
            Dict("file_path" => "/nonexistent/file.jl", "line" => 1, "column" => 1),
        )
        @test contains(result2, "Error") || contains(result2, "not found")

        # Test workspace_symbols with empty query
        ws_syms = filter(t -> t.name == "lsp_workspace_symbols", tools)[1]
        result3 = ws_syms.handler(Dict("query" => ""))
        @test contains(result3, "Error") || contains(result3, "required")
    end

    @testset "Tool Descriptions" begin
        tools = create_lsp_tools()

        for tool in tools
            # Each tool should have comprehensive documentation
            @test length(tool.description) > 100  # Substantial description
            @test contains(tool.description, "LSP") ||
                  contains(tool.description, "Language Server") ||
                  contains(tool.description, "Julia")

            # Should mention what it does
            if tool.name == "lsp_goto_definition"
                @test contains(tool.description, "definition")
            elseif tool.name == "lsp_find_references"
                @test contains(tool.description, "references")
            elseif tool.name == "lsp_hover_info"
                @test contains(tool.description, "hover") ||
                      contains(tool.description, "documentation")
            elseif tool.name == "lsp_document_symbols"
                @test contains(tool.description, "symbols")
            elseif tool.name == "lsp_workspace_symbols"
                @test contains(tool.description, "search") ||
                      contains(tool.description, "workspace")
            end
        end
    end
end
