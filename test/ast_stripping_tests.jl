using ReTest
using MCPRepl

@testset "AST Stripping Tests" begin
    @testset "Print Statement Removal" begin
        # Test println removal
        expr = Meta.parse("println(\"test\"); x = 42")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")

        # Test print removal
        expr = Meta.parse("print(\"test\"); y = 100")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "print")

        # Test printstyled removal
        expr = Meta.parse("printstyled(\"test\", color=:red); z = 200")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "printstyled")

        # Test qualified println removal (Base.println)
        expr = Meta.parse("Base.println(\"test\"); w = 300")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
    end

    @testset "@show Removal" begin
        # Test @show removal
        expr = Meta.parse("@show 42; x = 100")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "@show")
    end

    @testset "Logging Macro Removal - Top Level Only" begin
        # Test @info removal at top level
        expr = Meta.parse("@info \"test\"; x = 42")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "@info")

        # Test @error removal at top level
        expr = Meta.parse("@error \"test\"; y = 100")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "@error")

        # Test @warn removal at top level
        expr = Meta.parse("@warn \"test\"; z = 200")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "@warn")

        # Test @debug removal at top level
        expr = Meta.parse("@debug \"test\"; w = 300")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "@debug")
    end

    @testset "Logging Macros Preserved in Functions" begin
        # Test @info preserved inside function
        expr = Meta.parse("function test() @info \"inside\"; return 42 end")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test contains(string(cleaned), "@info")

        # Test @error preserved inside function
        expr = Meta.parse("function test() @error \"inside\"; return 42 end")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test contains(string(cleaned), "@error")

        # Test @warn preserved inside function
        expr = Meta.parse("function test() @warn \"inside\"; return 42 end")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test contains(string(cleaned), "@warn")
    end

    @testset "Print Statements Removed at All Levels" begin
        # Test println removed inside function
        expr = Meta.parse("function test() println(\"inside\"); return 42 end")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")

        # Test print removed in nested blocks
        expr = Meta.parse("let x = 10; print(\"nested\"); x + 1 end")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "print")
    end

    @testset "Code Logic Preserved" begin
        # Test that actual code remains intact
        expr = Meta.parse("println(\"remove me\"); x = 42; y = x + 1")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test contains(string(cleaned), "x = 42")
        @test contains(string(cleaned), "y = x + 1")

        # Test function definition preserved
        expr = Meta.parse("@info \"remove me\"; function foo(x) return x^2 end")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test contains(string(cleaned), "function foo")
        @test contains(string(cleaned), "x") && contains(string(cleaned), "2")
    end

    @testset "Multiple Statements" begin
        # Test multiple print statements removed
        expr = Meta.parse("println(\"a\"); print(\"b\"); @show 42; x = 100")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "println")
        @test !contains(string(cleaned), "print")
        @test !contains(string(cleaned), "@show")
        @test contains(string(cleaned), "x = 100")

        # Test multiple logging macros at top level
        expr = Meta.parse("@info \"a\"; @error \"b\"; @warn \"c\"; y = 200")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test !contains(string(cleaned), "@info")
        @test !contains(string(cleaned), "@error")
        @test !contains(string(cleaned), "@warn")
        @test contains(string(cleaned), "y = 200")
    end

    @testset "Edge Cases" begin
        # Test empty expression (parses to nothing)
        expr = Meta.parse("")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test cleaned === nothing  # Empty string parses to nothing

        # Test expression with only println (should return nothing when removed)
        expr = Meta.parse("println(\"only this\")")
        cleaned = MCPRepl.remove_println_calls(expr)
        @test cleaned === nothing

        # Test nested logging in try/catch (try/catch is a nested scope, so @error preserved)
        expr = Meta.parse("try @error \"in try\"; x = 1 catch; @error \"in catch\" end")
        cleaned = MCPRepl.remove_println_calls(expr)
        # @error should be preserved inside try/catch (nested scope)
        @test contains(string(cleaned), "@error")
    end
end
