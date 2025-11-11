module MCPReplTests
using ReTest

@testset "MCPRepl Tests" begin
    include("security_tests.jl")
    include("setup_tests.jl")
    include("server_tests.jl")
    include("call_tool_tests.jl")
    include("lsp_tests.jl")
    include("generate_tests.jl")
    include("ast_stripping_tests.jl")
end
end