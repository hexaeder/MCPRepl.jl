"""
Static Analysis Tests

Uses JET.jl to catch errors at "compile time" including:
- Undefined variable references
- Missing exports
- Type instabilities
- Method errors

Run this before commits to catch issues like missing exports from modules.
"""

using Test
using JET

@testset "Static Analysis" begin
    @testset "Module Loading" begin
        # Test that all modules load without UndefVarError
        @test_call report_call = true begin
            using MCPRepl
            MCPRepl
        end
    end

    @testset "Proxy Module Exports" begin
        # Check that Proxy module properly imports from Session module
        @test_call report_call = true begin
            include("../src/proxy.jl")
            # This will fail if Session.update_activity! is not exported
            MCPRepl.Proxy.update_activity!
        end
    end

    @testset "Session Module Exports" begin
        # Verify all expected exports exist
        @test_call report_call = true begin
            include("../src/session.jl")
            MCPRepl.Session.update_activity!
        end
    end

    @testset "Top-level Module Analysis" begin
        # Run JET analysis on the entire MCPRepl module
        # This catches undefined variables, type issues, etc.
        rep = report_package("MCPRepl"; ignored_modules = (AnyFrameModule(Test),))

        # Filter out known acceptable issues
        issues = filter(rep.res.inference_error_reports) do report
            # Ignore errors from test files
            !any(sf -> occursin("test/", string(sf.file)), report.vst)
        end

        if !isempty(issues)
            println("\n❌ Static analysis found issues:")
            for (i, issue) in enumerate(issues)
                println("\n$i. ", issue)
            end
        end

        @test isempty(issues)
    end

    @testset "Export Consistency Check" begin
        # Verify that all `using .Module` statements can resolve their names

        # Test Proxy module dependencies
        @testset "Proxy Dependencies" begin
            using MCPRepl.Proxy

            # These should all be available from imported modules
            @test isdefined(MCPRepl.Proxy, :Dashboard)
            @test isdefined(MCPRepl.Proxy, :Session)
            @test isdefined(MCPRepl.Proxy, :MCPSession)
            @test isdefined(MCPRepl.Proxy, :update_activity!)
            @test isdefined(MCPRepl.Proxy, :get_mcp_session)
            @test isdefined(MCPRepl.Proxy, :create_mcp_session)
        end

        # Test MCPServer module dependencies
        @testset "MCPServer Dependencies" begin
            using MCPRepl.MCPServer

            @test isdefined(MCPRepl.MCPServer, :Session)
            @test isdefined(MCPRepl.MCPServer, :MCPSession)
        end
    end
end
