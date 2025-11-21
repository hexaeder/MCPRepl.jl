using HTTP
using JSON
include("../src/proxy.jl")
using .Proxy

# Clear and register a test REPL
empty!(Proxy.REPL_REGISTRY)
Proxy.register_repl("test-repl", 3006; pid = 89715)

# Create a mock HTTP request with the header and body
headers = ["Content-Type" => "application/json", "X-MCPRepl-Target" => "test-repl"]

body = """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"""

# Create the HTTP.Request object
req = HTTP.Request("POST", "/", headers, body)

println("Request headers: ", req.headers)
println("Request body: ", String(req.body))
println("\nCalling handle_request...")

# First, test just the JSON parsing and conversion
parsed = JSON.parse(body)
println("\nParsed JSON type: ", typeof(parsed))
request_dict = parsed isa Dict ? parsed : Dict(String(k) => v for (k, v) in pairs(parsed))
println("Converted to Dict type: ", typeof(request_dict))
json_body = JSON.json(request_dict)
println("JSON.json output type: ", typeof(json_body))
println("JSON.json output length: ", length(json_body))
println("JSON.json output: ", json_body)

# Call handle_request
try
    response = Proxy.handle_request(req)
    println("\nResponse status: ", response.status)
    println("Response body: ", String(response.body)[1:min(200, length(response.body))])
catch e
    println("\nError: ", e)
    for (exc, bt) in Base.catch_stack()
        showerror(stdout, exc, bt)
        println()
    end
end

# Check the REPL status to see if error was captured
println("\n\nChecking REPL registry after error:")
repl = Proxy.get_repl("test-repl")
if repl !== nothing
    println("Status: ", repl.status)
    println("Last error: ", repl.last_error)
else
    println("REPL not found in registry")
end
