import re
import sys

def convert_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Pattern to match MCPTool( "name", with optional whitespace
    # Captures: tool_var = MCPTool(\n    "name",
    pattern = r'(\w+)\s*=\s*MCPTool\(\s*\n\s*"([^"]+)",\s*\n'
    
    def replacer(match):
        var_name = match.group(1)
        tool_name = match.group(2)
        # Convert name to symbol (keep underscores, replace hyphens)
        symbol_name = tool_name.replace('-', '_')
        return f'{var_name} = @mcp_tool(:{symbol_name},\n        '
    
    converted = re.sub(pattern, replacer, content)
    
    # Remove trailing commas before closing parens at the end of tool definitions
    # Pattern: end of function followed by comma and closing paren
    converted = re.sub(r'(\n\s+end),\s*\n\s*\)', r'\1\n    )', converted)
    
    with open(filepath, 'w') as f:
        f.write(converted)
    
    print(f"Converted {filepath}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        convert_file(sys.argv[1])
    else:
        print("Usage: python convert_mcprepl_tools.py <filepath>")
