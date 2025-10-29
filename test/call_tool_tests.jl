using Test
using MCPRepl
using MCPRepl: MCPTool

@testset "call_tool Function Tests" begin
    
    @testset "call_tool with Symbol" begin
        # Start server for testing
        MCPRepl.start!(; verbose=false)
        
        try
            # Test symbol-based call
            result = MCPRepl.call_tool(:investigate_environment, Dict())
            @test result isa String
            @test !isempty(result)
            
            # Test with parameters
            result2 = MCPRepl.call_tool(:search_methods, Dict("query" => "println"))
            @test result2 isa String
            @test contains(result2, "Methods") || contains(result2, "methods")
            
            # Test error handling - nonexistent tool
            @test_throws ErrorException MCPRepl.call_tool(:nonexistent_tool, Dict())
            
        finally
            MCPRepl.stop!()
        end
    end
    
    @testset "call_tool with String (deprecated)" begin
        MCPRepl.start!(; verbose=false)
        
        try
            # Test string-based call (should warn)
            result = @test_logs (:warn, r"deprecated") MCPRepl.call_tool("investigate_environment", Dict())
            @test result isa String
            @test !isempty(result)
            
        finally
            MCPRepl.stop!()
        end
    end
    
    @testset "call_tool Handler Signatures" begin
        MCPRepl.start!(; verbose=false)
        
        try
            # Test tool with (args, stream_channel) signature
            result = MCPRepl.call_tool(:exec_repl, Dict("expression" => "2 + 2", "silent" => true))
            @test result isa String
            
            # Test tool with (args) only signature
            result2 = MCPRepl.call_tool(:search_methods, Dict("query" => "println"))
            @test result2 isa String
            
        finally
            MCPRepl.stop!()
        end
    end
    
    @testset "call_tool Error Cases" begin
        # Test without server running
        @test_throws ErrorException MCPRepl.call_tool(:exec_repl, Dict())
        
        MCPRepl.start!(; verbose=false)
        
        try
            # Test missing required parameters
            result = MCPRepl.call_tool(:search_methods, Dict())
            @test contains(result, "Error") || contains(result, "required")
            
        finally
            MCPRepl.stop!()
        end
    end
end
