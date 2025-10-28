using Test

@testset "MCPRepl Tests" begin
    include("setup_tests.jl")
    include("server_tests.jl")
end
