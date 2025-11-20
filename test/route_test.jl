using HTTP
using JSON

# Simulate what happens in the proxy
json_str = """{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"""
parsed = JSON.parse(json_str)
println("Parsed type: ", typeof(parsed))

# Convert to Dict as done in handle_request
request_dict = parsed isa Dict ? parsed : Dict(String(k) => v for (k, v) in pairs(parsed))
println("Dict type: ", typeof(request_dict))
println("Dict contents: ", request_dict)

# Try to make the HTTP call as done in route_to_repl
backend_url = "http://127.0.0.1:3006/"
try
    response = HTTP.post(
        backend_url,
        ["Content-Type" => "application/json"],
        JSON.json(request_dict);
        readtimeout=30,
        connect_timeout=5
    )
    println("Success! Status: ", response.status)
    println("Body preview: ", String(response.body)[1:min(100, length(response.body))])
catch e
    println("Error: ", e)
    println("Error type: ", typeof(e))
end
