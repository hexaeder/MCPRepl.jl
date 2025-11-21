using HTTP
using JSON

# Test the proxy forwarding directly
println("Testing proxy forwarding...")

# Make a simple tools/list request
request = Dict(
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "tools/list"
)

println("Sending request to proxy...")
response = HTTP.post(
    "http://127.0.0.1:3000/",
    ["Content-Type" => "application/json"],
    JSON.json(request);
    readtimeout=10
)

println("Response status: ", response.status)
println("Response headers: ", response.headers)
println("Response body length: ", length(response.body))
println("Response body: ", String(response.body))

if !isempty(response.body)
    result = JSON.parse(String(response.body))
    println("Parsed result: ", result)
else
    println("ERROR: Empty response body!")
end
