#!/usr/bin/env python3
"""
Convert old MCPTool() constructors to @mcp_tool(...) macro syntax
"""
import re
import sys

def convert_tool(content):
    """Convert MCPTool constructors to @mcp_tool(...) macro format with parentheses"""
    
    # Pattern to match: tool_name = MCPTool(\n    "string_name",
    pattern = r'(\w+_tool) = MCPTool\(\s*\n\s*"([^"]+)",\s*\n'
    
    def replace_func(match):
        var_name = match.group(1)
        string_name = match.group(2)
        
        # Convert string name to symbol (remove hyphens, make underscore)
        symbol_name = string_name.replace('-', '_')
        
        # Return the macro invocation start with parentheses
        return f'{var_name} = @mcp_tool(:{symbol_name}, '
    
    # Replace all occurrences
    new_content = re.sub(pattern, replace_func, content)
    
    # Now remove trailing commas after function end - change end,\n    ) to end\n    )
    new_content = re.sub(r'(\n\s+end),\s*\n(\s*\))', r'\1\n\2', new_content)
    
    return new_content

def main():
    file_path = sys.argv[1] if len(sys.argv) > 1 else 'src/lsp.jl'
    
    with open(file_path, 'r') as f:
        content = f.read()
    
    new_content = convert_tool(content)
    
    with open(file_path, 'w') as f:
        f.write(new_content)
    
    print(f"Converted {file_path}")

if __name__ == '__main__':
    main()
