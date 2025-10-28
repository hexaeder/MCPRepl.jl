using Test

@testset "MCPRepl Tests" begin
    include("security_tests.jl")
    include("setup_tests.jl")
    include("server_tests.jl")
end
