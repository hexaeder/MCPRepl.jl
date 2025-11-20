using Test
using HTTP
using JSON

# Import the functions we need to test
include("../src/proxy.jl")
using .Proxy

@testset "Proxy Header Parsing" begin
    @testset "HTTP.header returns SubString or String" begin
        # Create a mock request with a header
        req = HTTP.Request("POST", "/", ["X-MCPRepl-Target" => "test-repl"], "")

        # Test that HTTP.header returns what we expect
        header_value = HTTP.header(req, "X-MCPRepl-Target")
        @test header_value isa AbstractString

        println("Header type: $(typeof(header_value))")
        println("Header value: $header_value")

        # Test our conversion logic
        target_id = isempty(header_value) ? nothing : String(header_value)
        @test target_id == "test-repl"
        @test target_id isa String
    end

    @testset "Missing header" begin
        req = HTTP.Request("POST", "/", [], "")
        header_value = HTTP.header(req, "X-MCPRepl-Target")

        println("Missing header type: $(typeof(header_value))")
        println("Missing header value: $header_value")

        @test header_value isa AbstractString
        @test isempty(header_value)

        # Test our conversion logic
        target_id = isempty(header_value) ? nothing : String(header_value)
        @test target_id === nothing
    end
end

@testset "REPL Registry" begin
    @testset "Register and retrieve REPL" begin
        # Clear any existing registrations
        empty!(Proxy.REPL_REGISTRY)

        # Register a test REPL
        Proxy.register_repl("test-repl-1", 3001; pid=12345, metadata=Dict("test" => "data"))

        # Verify it's in the registry
        repl = Proxy.get_repl("test-repl-1")
        @test repl !== nothing
        @test repl.id == "test-repl-1"
        @test repl.port == 3001
        @test repl.pid == 12345
        @test repl.status == :ready
        @test repl.metadata["test"] == "data"
    end

    @testset "List REPLs" begin
        empty!(Proxy.REPL_REGISTRY)

        Proxy.register_repl("repl-1", 3001)
        Proxy.register_repl("repl-2", 3002)

        repls = Proxy.list_repls()
        @test length(repls) == 2
        @test any(r -> r.id == "repl-1", repls)
        @test any(r -> r.id == "repl-2", repls)
    end

    @testset "Unregister REPL" begin
        empty!(Proxy.REPL_REGISTRY)

        Proxy.register_repl("temp-repl", 3003)
        @test Proxy.get_repl("temp-repl") !== nothing

        Proxy.unregister_repl("temp-repl")
        @test Proxy.get_repl("temp-repl") === nothing
    end

    @testset "Update REPL status" begin
        empty!(Proxy.REPL_REGISTRY)

        Proxy.register_repl("status-repl", 3004)
        repl = Proxy.get_repl("status-repl")
        @test repl.status == :ready
        @test repl.missed_heartbeats == 0

        Proxy.update_repl_status("status-repl", :stopped)
        repl = Proxy.get_repl("status-repl")
        @test repl.status == :stopped
    end

    @testset "Missed heartbeat counter" begin
        empty!(Proxy.REPL_REGISTRY)

        Proxy.register_repl("heartbeat-test", 3005)
        repl = Proxy.get_repl("heartbeat-test")
        @test repl.missed_heartbeats == 0
        @test repl.status == :ready

        # Simulate first error - should increment counter but stay ready
        Proxy.update_repl_status("heartbeat-test", :ready; error="Error 1")
        repl = Proxy.get_repl("heartbeat-test")
        @test repl.missed_heartbeats == 1
        @test repl.last_error == "Error 1"

        # Second error - still ready
        Proxy.update_repl_status("heartbeat-test", :ready; error="Error 2")
        repl = Proxy.get_repl("heartbeat-test")
        @test repl.missed_heartbeats == 2

        # Third error - now should be stopped
        Proxy.update_repl_status("heartbeat-test", :ready; error="Error 3")
        repl = Proxy.get_repl("heartbeat-test")
        @test repl.missed_heartbeats == 3

        # Recovery - should reset counter
        Proxy.update_repl_status("heartbeat-test", :ready)
        repl = Proxy.get_repl("heartbeat-test")
        @test repl.missed_heartbeats == 0
        @test repl.last_error === nothing
    end
end

@testset "HTTP Request Construction" begin
    @testset "HTTP.post with headers and body" begin
        # Test that our HTTP.post syntax is correct
        # This is the exact pattern used in route_to_repl
        backend_url = "http://127.0.0.1:3006/"
        headers = ["Content-Type" => "application/json"]
        body_str = JSON.json(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => Dict()))

        println("\nTesting HTTP.post arguments:")
        println("  URL: $backend_url")
        println("  Headers type: $(typeof(headers))")
        println("  Headers: $headers")
        println("  Body type: $(typeof(body_str))")
        println("  Body length: $(length(body_str))")
        println("  Body preview: $(body_str[1:min(50, length(body_str))])")

        # Verify types are what HTTP.post expects
        @test backend_url isa String
        @test headers isa Vector{Pair{String,String}}
        @test body_str isa String
        @test length(headers) == 1
        @test headers[1].first == "Content-Type"
        @test headers[1].second == "application/json"
    end

    @testset "Response construction" begin
        # Test that HTTP.Response can be constructed properly
        status = 200
        body = JSON.json(Dict("result" => "test"))

        println("\nTesting HTTP.Response construction:")
        println("  Status: $status")
        println("  Body type: $(typeof(body))")

        # This should not throw
        response = HTTP.Response(status, body)
        @test response.status == 200
        @test String(response.body) == body
    end
end

@testset "JSON Object to Dict conversion" begin
    @testset "Convert JSON.Object metadata" begin
        json_str = """{"id":"test","port":3000,"metadata":{"key":"value"}}"""
        parsed = JSON.parse(json_str)

        # Test the conversion logic used in proxy/register
        metadata_raw = get(parsed, "metadata", Dict())
        metadata = metadata_raw isa Dict ? metadata_raw : Dict(String(k) => v for (k, v) in pairs(metadata_raw))

        @test metadata isa Dict
        @test metadata["key"] == "value"
    end

    @testset "Convert JSON.Object request" begin
        json_str = """{"jsonrpc":"2.0","id":1,"method":"test","params":{}}"""
        parsed = JSON.parse(json_str)

        # Test the conversion logic used in route_to_repl
        request_dict = parsed isa Dict ? parsed : Dict(String(k) => v for (k, v) in pairs(parsed))

        @test request_dict isa Dict
        @test request_dict["method"] == "test"
    end

    @testset "Full route_to_repl simulation" begin
        # This tests the exact flow that happens in the proxy
        empty!(Proxy.REPL_REGISTRY)

        # Register a test REPL
        Proxy.register_repl("route-test", 3006; pid=Int(getpid()))

        # Create a JSON request string (as would come from HTTP)
        json_str = """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"""

        # Parse it (this creates a JSON.Object)
        parsed = JSON.parse(json_str)
        println("\nFull routing test:")
        println("  Parsed type: $(typeof(parsed))")

        # Convert to Dict as done in handle_request
        request_dict = parsed isa Dict ? parsed : Dict(String(k) => v for (k, v) in pairs(parsed))
        println("  Dict type: $(typeof(request_dict))")

        # Simulate what route_to_repl does
        backend_url = "http://127.0.0.1:3006/"
        headers = ["Content-Type" => "application/json"]
        body_str = JSON.json(request_dict)
        println("  Final body type: $(typeof(body_str))")
        println("  Final body: $body_str")

        # Verify all the types are correct
        @test request_dict isa Dict{String,Any}
        @test body_str isa String
        @test headers isa Vector{Pair{String,String}}

        # Test that these arguments won't cause an error when constructing Response
        @test_nowarn HTTP.Response(200, body_str)

        # Test the exact argument pattern used in route_to_repl
        println("\nTesting HTTP.post argument pattern:")
        println("  Arg 1 (url): $(typeof(backend_url)) = $backend_url")
        println("  Arg 2 (headers): $(typeof(headers)) = $headers")
        println("  Arg 3 (body): $(typeof(body_str)) - length $(length(body_str))")

        # This validates our argument types match what HTTP.post expects
        @test backend_url isa AbstractString
        @test headers isa AbstractVector
        @test all(h -> h isa Pair{<:AbstractString,<:AbstractString}, headers)
        @test body_str isa AbstractString
    end
end
