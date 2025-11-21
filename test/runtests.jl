using ReTest

# Include all test files (both from templates and multi-agent)
include("security_tests.jl")
include("setup_tests.jl")
include("server_tests.jl")
include("session_tests.jl")
include("call_tool_tests.jl")
include("lsp_tests.jl")
include("generate_tests.jl")
include("ast_stripping_tests.jl")
include("version_tests.jl")
include("supervisor_tests.jl")
include("proxy_state_tests.jl")

# Run all tests with ReTest
retest()
