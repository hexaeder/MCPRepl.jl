using MCPRepl

# Tool 1: Get current time
time_tool = MCPTool(
    "get_time",
    "Get current time in specified format",
    MCPRepl.text_parameter("format", "DateTime format string (e.g., 'yyyy-mm-dd HH:MM:SS')"),
    args -> Dates.format(now(), get(args, "format", "yyyy-mm-dd HH:MM:SS"))
)

# Tool 2: Reverse text
reverse_tool = MCPTool(
    "reverse_text",
    "Reverse the input text",
    MCPRepl.text_parameter("text", "Text to reverse"),
    args -> reverse(get(args, "text", ""))
)

# Tool 3: Count words
word_count_tool = MCPTool(
    "count_words",
    "Count words in the input text",
    MCPRepl.text_parameter("text", "Text to count words in"),
    args -> string(length(split(get(args, "text", ""))))
)

# Tool 4: Julia eval (simple calculator)
calc_tool = MCPTool(
    "calculate",
    "Evaluate a simple Julia expression",
    MCPRepl.text_parameter("expression", "Julia expression to evaluate (e.g., '2 + 3 * 4')"),
    args -> begin
        try
            expr = Meta.parse(get(args, "expression", "0"))
            result = eval(expr)
            string(result)
        catch e
            "Error: $e"
        end
    end
)

# Start server with all tools
tools = [time_tool, reverse_tool, word_count_tool, calc_tool]
server = MCPRepl.start_mcp_server(tools, 3000)

println("Server started with tools:")
for tool in tools
    println("  - $(tool.name): $(tool.description)")
end
println("\nPress Ctrl+C to stop server...")

using MCPRepl
MCPRepl.start!()
