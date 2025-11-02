# MCPRepl Tool Configuration

This directory contains configuration files for customizing your MCPRepl MCP server behavior.

## Tool Configuration (`tools.json`)

The `tools.json` file allows you to control which MCP tools are enabled on your server, helping you reduce token usage by disabling tools you don't need.

### Token Usage

With all tools enabled, the MCP server uses **~13,000 tokens** in the Claude prompt.

The default configuration reduces this to **~5,500 tokens** (58% reduction), and you can customize further based on your needs.

### Configuration Structure

```json
{
  "tool_sets": {
    "set-name": {
      "enabled": true/false,
      "description": "Description of what this set does",
      "tokens": "~X,XXX",
      "tools": ["tool1", "tool2", ...]
    }
  },
  "individual_overrides": {
    "specific_tool": true/false
  }
}
```

### Available Tool Sets

| Tool Set | Tokens | Default | Description |
|----------|--------|---------|-------------|
| **core** | ~600 | ✓ Enabled | Essential tools (ping, usage_instructions, investigate_environment, tool_help, restart_repl) |
| **execution** | ~500 | ✓ Enabled | REPL code execution (ex) - Required for basic functionality |
| **code-analysis** | ~200 | ✓ Enabled | Basic code introspection (type_info, search_methods, list_names) |
| **advanced-analysis** | ~300 | ✗ Disabled | Advanced code inspection (macro_expand, code_lowered, code_typed, profile_code) |
| **code-quality** | ~100 | ✓ Enabled | Formatting and linting (format_code, lint_package) |
| **lsp** | ~400 | ✗ Disabled | Language Server Protocol integrations (document symbols, goto definition, find references, code actions, rename) |
| **debugging** | ~1,000 | ✗ Disabled | Interactive debugging (breakpoints, stepping, watch expressions) |
| **package-management** | ~100 | ✓ Enabled | Package operations (pkg_add, pkg_rm) |
| **vscode** | ~200 | ✗ Disabled | VS Code editor integration (execute commands, list commands) |
| **education** | ~1,000 | ✗ Disabled | Learning tools (usage_quiz) |

### Usage Examples

#### Minimal Configuration (Core + Execution only)
Save ~20,000 tokens by only enabling essential functionality:

```json
{
  "tool_sets": {
    "core": { "enabled": true },
    "execution": { "enabled": true },
    "code-analysis": { "enabled": false },
    "code-quality": { "enabled": false },
    "lsp": { "enabled": false },
    "debugging": { "enabled": false },
    "package-management": { "enabled": false },
    "vscode": { "enabled": false },
    "education": { "enabled": false }
  }
}
```

#### Enable Debugging Tools
When you need to debug, temporarily enable debugging tools:

```json
{
  "tool_sets": {
    "debugging": { "enabled": true }
  }
}
```

#### Override Individual Tools
Enable a specific tool even if its set is disabled:

```json
{
  "tool_sets": {
    "debugging": { "enabled": false }
  },
  "individual_overrides": {
    "open_file_and_set_breakpoint": true
  }
}
```

Or disable a specific tool even if its set is enabled:

```json
{
  "tool_sets": {
    "code-analysis": { "enabled": true }
  },
  "individual_overrides": {
    "profile_code": false
  }
}
```

### Applying Changes

After modifying `tools.json`, restart the MCP server:

```julia
julia> MCPRepl.stop!()
julia> MCPRepl.start!()
```

The startup message will show how many tools are enabled vs disabled:

```
🔧 Tools: 22 enabled, 13 disabled by config
🚀 MCP Server running on port 3000 with 22 tools
```

### Backward Compatibility

If `.mcprepl/tools.json` doesn't exist, all tools will be enabled by default. This ensures existing installations continue working without changes.

### Recommendations

**For general development (default config):**
- Enable: core, execution, code-analysis, code-quality, package-management
- Disable: advanced-analysis, lsp, debugging, vscode, education
- **Token usage: ~5,500** ⭐ Recommended

**For advanced code analysis:**
- Add: advanced-analysis
- **Token usage: ~5,800**

**For debugging sessions:**
- Add: debugging (and optionally advanced-analysis)
- **Token usage: ~6,800** (with both)

**For VS Code integration:**
- Add: vscode
- **Token usage: ~5,700**

**When using LSP features (if you have Julia LSP server running):**
- Add: lsp
- **Token usage: ~5,900**
