# CRUSH.md - MCPRepl.jl Development Guide

Guide for AI agents working on MCPRepl.jl - a Julia package that exposes a REPL as an MCP server for AI agent integration.

---

## Project Overview

**What is MCPRepl.jl?**
- Julia package that exposes your REPL as an MCP (Model Context Protocol) server
- Enables AI agents to execute code in the user's Julia REPL
- **Shared REPL model**: User and agent work in the same REPL state - user sees all agent commands in real-time
- Key features: Security (API keys, IP allowlisting), LSP integration, VS Code command execution

**Core Philosophy**
- REPL-driven development is the best way to work in Julia
- AI agents should learn this workflow too
- Security-first design with multiple modes (:strict, :relaxed, :lax)
- Real-time visibility: user sees everything the agent does

---

## Essential Commands

### Development & Testing

```bash
# Run test suite (recommended)
julia --project -e 'using Pkg; Pkg.test()'

# Build package
julia --project -e 'using Pkg; Pkg.build()'

# Start Julia REPL with project
julia --project

# In REPL: Load and start server
using MCPRepl
MCPRepl.start!()
```

### Testing in REPL

```julia
# Load package in dev mode
using Pkg; Pkg.activate(".")
using MCPRepl

# Run specific test file
include("test/security_tests.jl")

# Run all tests
Pkg.test("MCPRepl")
```

### Code Quality

```julia
# Format code (requires JuliaFormatter.jl in test environment)
using JuliaFormatter
format("src/")
format("test/")

# Lint package (requires Aqua.jl in test environment)
using Aqua
Aqua.test_all(MCPRepl)
```

---

## Project Structure

```
MCPRepl.jl/
├── src/
│   ├── MCPRepl.jl          # Main module, execute_repllike, tool definitions
│   ├── MCPServer.jl        # HTTP server, tool registry, request handling
│   ├── security.jl         # API key generation, IP validation, security config
│   ├── security_wizard.jl  # Interactive setup wizards (dragon/butterfly themes)
│   ├── setup.jl            # VS Code configuration, workspace setup
│   ├── lsp.jl              # Language Server Protocol integration
│   ├── vscode.jl           # VS Code command execution via URIs
│   └── Generate.jl         # Project template generator
├── test/
│   ├── runtests.jl         # Test suite entry point
│   ├── security_tests.jl   # API key, IP validation tests
│   ├── server_tests.jl     # MCP server tests
│   ├── lsp_tests.jl        # LSP integration tests
│   ├── setup_tests.jl      # Setup and configuration tests
│   ├── generate_tests.jl   # Template generation tests
│   ├── call_tool_tests.jl  # Tool call and routing tests
│   └── ast_stripping_tests.jl  # Quiet mode println removal tests
├── prompts/
│   ├── julia_repl_workflow.md      # Agent usage instructions
│   ├── usage_quiz_questions.md     # Self-assessment quiz
│   └── usage_quiz_solutions.md     # Quiz answers and grading
├── extended-help/          # Detailed help for individual tools
│   ├── ex.md
│   ├── investigate_environment.md
│   ├── format_code.md
│   └── ...
├── .mcprepl/              # Generated config (gitignored)
│   ├── security.json       # API keys, allowed IPs, security mode
│   ├── tools.json          # Tool enablement configuration
│   └── tools-schema.json   # JSON schema for tools config
├── .github/
│   └── workflows/
│       └── CI.yml          # GitHub Actions CI (Julia 1, lts, pre on Ubuntu)
├── Project.toml           # Package metadata and dependencies
└── README.md              # User-facing documentation
```

---

## Code Organization & Patterns

### Module Structure

**Main Module (`MCPRepl.jl`)**
- Exports `@mcp_tool` macro for tool definitions
- Includes all submodules: security, server, setup, LSP, vscode, Generate
- Defines core execution function: `execute_repllike()`
- Manages VS Code response storage and nonce authentication
- Provides `start!()` and `stop!()` server lifecycle functions

**Core Types**
```julia
# Tool definition
struct MCPTool
    id::Symbol              # Internal identifier (e.g., :ex)
    name::String            # JSON-RPC name (e.g., "ex")
    description::String     # Tool documentation
    parameters::Dict{String,Any}  # JSON schema for parameters
    handler::Function       # (args) -> String or (args, stream) -> String
end

# Security configuration
struct SecurityConfig
    mode::Symbol            # :strict, :relaxed, or :lax
    api_keys::Vector{String}
    allowed_ips::Vector{String}
    port::Int
    created_at::Int64
end

# MCP Server
struct MCPServer
    port::Int
    server::HTTP.Server
    tools::Dict{Symbol,MCPTool}        # Symbol-keyed tool registry
    name_to_id::Dict{String,Symbol}    # String→Symbol lookup
end
```

### Naming Conventions

**Julia Code**
- Functions: `snake_case` (e.g., `execute_repllike`, `validate_api_key`)
- Types: `PascalCase` (e.g., `MCPTool`, `SecurityConfig`)
- Constants: `UPPER_SNAKE_CASE` (e.g., `VSCODE_RESPONSES`, `SERVER`)
- Private functions: Often start with underscore (optional)

**Tool Names**
- Tool IDs are symbols: `:ex`, `:ping`, `:investigate_environment`
- Tool names are strings: `"ex"`, `"ping"`, `"investigate_environment"`
- Use snake_case for consistency

**VS Code Commands**
- Follow VS Code convention: `namespace.action.specifics`
- Examples: `workbench.action.files.saveAll`, `language-julia.restartREPL`

### Code Style

**Function Definitions**
```julia
# Preferred: Multi-line for functions with parameters
function execute_repllike(
    str;
    silent::Bool = false,
    quiet::Bool = true,
    description::Union{String,Nothing} = nothing,
)
    # function body
end

# Short functions: Single line
text_parameter(name, desc) = Dict("type" => "string", "description" => desc)
```

**Docstrings**
```julia
"""
    function_name(arg1, arg2; kwarg=default)

Brief description of what the function does.

# Arguments
- `arg1`: Description
- `arg2`: Description
- `kwarg`: Description (default: default)

# Returns
- Description of return value

# Examples
```julia
result = function_name("value", 42)
```
"""
```

**Error Handling**
```julia
# Prefer returning error strings from tool handlers
args -> begin
    try
        # ... operation
        return "Success message"
    catch e
        return "Error: $e"
    end
end

# Use @warn for non-fatal issues
@warn "Failed to load config, using defaults" exception=e

# Use error() for fatal issues
if !isfile(required_file)
    error("Required file not found: $required_file")
end
```

---

## Key Concepts

### The @mcp_tool Macro

Define MCP tools with symbol-based identification:

```julia
tool = @mcp_tool(
    :tool_id,                    # Symbol ID (becomes both ID and name)
    "Description of the tool",
    Dict(                         # JSON schema for parameters
        "type" => "object",
        "properties" => Dict(
            "param" => Dict("type" => "string")
        ),
        "required" => ["param"]
    ),
    args -> begin                # Handler function
        param_value = get(args, "param", "")
        # ... do work
        return "Result string"
    end
)
```

### Execute REPL-like Function

**Core execution:** `execute_repllike(str; silent=false, quiet=true, description=nothing)`

**Key behaviors:**
- Parses Julia code and evaluates on REPL backend
- `quiet=true` (default): Appends semicolon, strips println/logging calls from AST, returns only result
- `quiet=false`: Returns captured stdout/stderr + result
- `silent=true`: Suppresses "agent>" prompt and real-time output
- Blocks `Pkg.activate()` calls (use `# overwrite no-activate-rule` to bypass)
- Shows real-time output to user unless silent mode

**AST Stripping in Quiet Mode:**
```julia
function remove_println_calls(expr, toplevel::Bool=true)
    # Removes: println, print, printstyled, @show
    # Removes logging macros (@error, @info, @warn, @debug) at top level only
    # Preserves them inside function definitions
end
```

### Security System

**Three Modes:**
1. **`:strict`** (default): Requires API key AND IP allowlist
2. **`:relaxed`**: Requires API key, accepts any IP
3. **`:lax`**: Localhost-only (127.0.0.1, ::1), no API key required

**API Key Format:** `mcprepl_<40 hex chars>` (20 random bytes)

**Configuration Files:**
- Location: `.mcprepl/security.json` (gitignored)
- Generated by: `MCPRepl.setup()` or `MCPRepl.quick_setup(:mode)`
- Functions: `load_security_config()`, `save_security_config(config)`

**Security Checks:**
1. Extract API key from `Authorization: Bearer <key>` header
2. Validate against stored keys
3. Check client IP against allowlist (strict mode only)
4. Special nonce authentication for VS Code callbacks

### VS Code Integration

**URI-based Command Execution:**
```julia
# Build URI for VS Code command
uri = build_vscode_uri(
    "command.name";
    args = HTTP.URIs.escapeuri(JSON.json([arg1, arg2])),
    request_id = "unique_id",  # For response tracking
    nonce = "secure_nonce",    # For callback authentication
    mcp_port = 3000
)

# Trigger command (opens vscode:// URI)
trigger_vscode_uri(uri)
```

**Bidirectional Communication:**
- Agent sends command with `request_id`
- VS Code executes command, posts result to `/vscode-response` endpoint
- Agent retrieves result with `retrieve_vscode_response(request_id; timeout=5.0)`
- Uses single-use nonces for callback authentication

### LSP Integration

**Tools for code navigation and refactoring:**
- `lsp_goto_definition`, `lsp_find_references`, `lsp_document_symbols`
- `lsp_rename`, `lsp_code_actions`, `lsp_format_document`
- Implemented in `src/lsp.jl`
- Communicate with Julia Language Server in VS Code

**Note:** For documentation and type info, prefer Julia REPL introspection:
```julia
@doc function_name      # Documentation
methods(function_name)  # Method signatures
fieldnames(Type)        # Type fields
```

### Tool Configuration

**Location:** `.mcprepl/tools.json`

**Structure:**
```json
{
  "tool_sets": {
    "core": {
      "enabled": true,
      "tools": ["ex", "ping", "investigate_environment"]
    },
    "lsp": {
      "enabled": false,
      "tools": ["lsp_goto_definition", "lsp_find_references"]
    }
  },
  "individual_overrides": {
    "format_code": false,
    "_comment": "Individual settings override tool sets"
  }
}
```

**Loading Logic:**
1. If no config file exists, all tools enabled (backward compatibility)
2. Enable tools from enabled tool sets
3. Apply individual overrides (precedence over sets)

---

## Testing Approach

### Test Organization

**Test Suite Structure:**
- Entry point: `test/runtests.jl` includes all test files
- Each test file covers a specific module or feature
- Uses `@testset` for grouping related tests
- Includes setup/teardown with temporary directories

### Running Tests

```julia
# Full test suite
using Pkg
Pkg.test("MCPRepl")

# Individual test file (useful during development)
include("test/security_tests.jl")
```

### Test Patterns

**Setup and Cleanup:**
```julia
@testset "Feature Tests" begin
    test_dir = mktempdir()
    original_dir = pwd()
    
    try
        cd(test_dir)
        # ... tests
    finally
        cd(original_dir)
        rm(test_dir; recursive=true, force=true)
    end
end
```

**Testing Tool Handlers:**
```julia
@testset "Tool Handler" begin
    # Create tool
    tool = @mcp_tool(:test, "desc", params, handler)
    
    # Call handler directly
    result = tool.handler(Dict("param" => "value"))
    
    # Assert result
    @test contains(result, "expected output")
end
```

**Security Testing:**
```julia
# API key validation
key = MCPRepl.generate_api_key()
@test startswith(key, "mcprepl_")
@test occursin(r"^mcprepl_[0-9a-f]{40}$", key)

# Config save/load
config = MCPRepl.SecurityConfig(:strict, [key], ["127.0.0.1"])
@test MCPRepl.save_security_config(config, test_dir)
loaded = MCPRepl.load_security_config(test_dir)
@test loaded.mode == :strict
```

### CI Configuration

**GitHub Actions** (`.github/workflows/CI.yml`):
- Runs on: Ubuntu latest
- Julia versions: 1 (stable), lts (long-term support), pre (nightly)
- Steps: checkout, setup Julia, cache packages, build, test
- Uses `julia-actions/cache@v2` for package caching

---

## Important Gotchas

### Never Use Pkg.activate()

**Forbidden by design:** `execute_repllike()` blocks calls to `Pkg.activate()`

**Reason:** Agent should work in the user's current environment, not change it

**Error message:**
```
ERROR: Using Pkg.activate to change environments is not allowed.
You should assume you are in the correct environment for your tasks.
```

**Bypass (if needed):** Add comment `# overwrite no-activate-rule` to the command

**Recommended:** Use `MCPRepl.repl_status_report()` or `investigate_environment` tool to check environment

### Quiet Mode Token Savings

**Default behavior** (`q=true`):
- Appends semicolon to suppress return value
- Strips `println`, `print`, `printstyled`, `@show` from AST
- Removes top-level logging macros (`@info`, `@warn`, `@error`, `@debug`)
- Saves 70-90% of tokens by not returning captured output

**When to use `q=false`:**
- Need return value to make a decision
- Inspecting results for comparison
- Getting method signatures or type information

**Anti-patterns:**
```julia
# DON'T use q=false for:
ex(e="x = 42", q=false)              # Assignment
ex(e="using Pkg", q=false)            # Import
ex(e="function f() end", q=false)     # Definition
ex(e="println('hello')", q=false)     # Output (user sees it anyway)
```

### Revise.jl Integration

**What it does:**
- Auto-tracks changes in development packages (those in `src/` directories)
- Reloads code changes without restarting REPL
- Shown in `investigate_environment` output

**When it fails (rare):**
1. Check for errors: `Revise.errors()`
2. If needed: Use `restart_repl()` tool
3. Wait 5-10 seconds for REPL to restart
4. Use `ping()` to verify server is back

### VS Code Remote Control Extension

**Required for:**
- `execute_vscode_command` tool
- `restart_repl` tool
- All debugging workflow tools

**Installation:** Run `MCPRepl.setup()` which:
1. Installs extension from VSIX file
2. Adds allowed commands to `.vscode/settings.json`
3. Creates MCP server configuration

**Allowed commands list:** See `Generate.VSCODE_ALLOWED_COMMANDS` constant

### Security Configuration Required

**Server won't start without security config:**
```julia
julia> MCPRepl.start!()
⚠️  NO SECURITY CONFIGURATION FOUND
ERROR: Security configuration required. Run MCPRepl.setup() first.
```

**Setup options:**
```julia
MCPRepl.setup()                    # Interactive wizard (dragon theme)
MCPRepl.setup(; gentle=true)       # Interactive wizard (butterfly theme)
MCPRepl.quick_setup(:lax)          # Quick setup for local development
MCPRepl.quick_setup(:strict)       # Quick setup for production
```

**Configuration location:** `.mcprepl/security.json` (auto-added to `.gitignore`)

### Thread Safety for Shared State

**Global state with locks:**
```julia
const VSCODE_RESPONSES = Dict{String,Tuple{Any,Union{Nothing,String},Float64}}()
const VSCODE_RESPONSE_LOCK = ReentrantLock()

# Always use locks when accessing shared state
lock(VSCODE_RESPONSE_LOCK) do
    VSCODE_RESPONSES[request_id] = (result, error, time())
end
```

**Cleanup functions:** Periodically called to prevent memory leaks
- `cleanup_old_vscode_responses(max_age=60.0)`
- `cleanup_old_nonces(max_age=60.0)`

### AST Expression Handling

**Parsing user input:**
```julia
expr = Base.parse_input_line(str)  # Not Meta.parse() - handles multiple expressions
```

**AST modification in quiet mode:**
- Recursively walks expression tree
- Removes specific call expressions
- Rebuilds blocks with filtered statements
- Respects nested scopes (function, let, do, try, ->)

**Logging macros:** Only removed at top level, preserved in function definitions

---

## Working with This Codebase

### Before Making Changes

1. **Read relevant source files** to understand current implementation
2. **Check existing tests** to understand expected behavior
3. **Review security implications** for any server/network code
4. **Check for similar patterns** in the codebase

### Making Changes

1. **Follow existing patterns** for consistency
2. **Add tests** for new functionality
3. **Update docstrings** for public functions
4. **Run tests** before committing: `Pkg.test("MCPRepl")`
5. **Format code** if JuliaFormatter is available
6. **Check for type stability** in hot paths (use `@code_warntype`)

### Common Tasks

**Adding a new MCP tool:**
1. Define tool using `@mcp_tool` macro in `start!()` function
2. Add to tools vector passed to `start_mcp_server()`
3. Create extended help file in `extended-help/<tool_name>.md`
4. Add to tools.json schema if part of a tool set
5. Add tests in `test/call_tool_tests.jl` or new file
6. Update documentation in README.md

**Modifying security:**
1. Update `SecurityConfig` struct if needed
2. Modify validation logic in `security.jl`
3. Update setup wizards in `security_wizard.jl`
4. Add tests in `test/security_tests.jl`
5. Update README security section

**Adding VS Code commands:**
1. Add command to `VSCODE_ALLOWED_COMMANDS` in `Generate.jl`
2. Create tool handler using `build_vscode_uri()` and `trigger_vscode_uri()`
3. Test in actual VS Code environment
4. Document in extended help

**Modifying execute_repllike:**
1. Understand impact on quiet mode behavior
2. Update AST stripping logic if needed
3. Add tests in `test/ast_stripping_tests.jl`
4. Update usage instructions in `prompts/julia_repl_workflow.md`

### Debugging Tips

**Test a single function:**
```julia
julia --project
using MCPRepl
# Directly call internal functions
result = MCPRepl.execute_repllike("2 + 2"; quiet=false)
```

**Check server request handling:**
```julia
# Start server
MCPRepl.start!()

# In another terminal, make HTTP request
curl -X POST http://localhost:3000 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer mcprepl_YOUR_KEY" \
  -d '{"method":"ex","params":{"e":"2+2"}}'
```

**Inspect tool registry:**
```julia
server = MCPRepl.SERVER[]
# List all registered tools
for (id, tool) in server.tools
    println("$id => $(tool.name)")
end
```

**Check security config:**
```julia
config = MCPRepl.load_security_config()
println("Mode: $(config.mode)")
println("API keys: $(length(config.api_keys))")
println("Allowed IPs: $(config.allowed_ips)")
```

---

## Dependencies

**Required (in Project.toml):**
- HTTP.jl - HTTP server
- JSON.jl - JSON parsing and generation
- REPL.jl - REPL backend interaction
- Suppressor.jl - Output suppression
- SHA.jl - Cryptographic hashing for API keys
- Random.jl - Secure random number generation
- Dates.jl - Timestamp handling
- Pkg.jl - Package management
- InteractiveUtils.jl - REPL introspection
- Profile.jl - Code profiling support
- Printf.jl - Formatted output

**Test-only (in [extras]):**
- Test.jl - Test framework
- Aqua.jl - Package quality assurance
- JuliaFormatter.jl - Code formatting

**Julia Version:** 1.10 or later

---

## Related Files & Resources

**Documentation:**
- `README.md` - User-facing documentation with installation, usage, security
- `prompts/julia_repl_workflow.md` - Comprehensive agent workflow guide
- `extended-help/*.md` - Detailed help for individual tools

**Configuration:**
- `.mcprepl/security.json` - Security settings (gitignored)
- `.mcprepl/tools.json` - Tool enablement config
- `.vscode/settings.json` - VS Code Remote Control allowed commands
- `.vscode/mcp.json` - VS Code MCP server entries

**Testing:**
- `.github/workflows/CI.yml` - CI configuration
- `test/runtests.jl` - Test suite entry point
- `test/*_tests.jl` - Individual test files

---

## Quick Reference

**Start development:**
```bash
git clone https://github.com/kahliburke/MCPRepl.jl
cd MCPRepl.jl
julia --project
```

**In Julia REPL:**
```julia
# Install dependencies
using Pkg
Pkg.instantiate()

# Load package
using MCPRepl

# Run setup (first time only)
MCPRepl.quick_setup(:lax)

# Start server
MCPRepl.start!()

# Run tests
Pkg.test()
```

**Common operations:**
```julia
# Check environment
MCPRepl.repl_status_report()

# Security management
MCPRepl.security_status()
MCPRepl.generate_key()
MCPRepl.allow_ip("192.168.1.100")

# Reset everything
MCPRepl.reset()  # Removes .mcprepl/, startup scripts, vscode config
```

---

## Questions or Issues?

**When stuck:**
1. Check this CRUSH.md for patterns and gotchas
2. Read relevant source files for implementation details
3. Check tests for usage examples
4. Review `prompts/julia_repl_workflow.md` for agent workflow
5. Look for similar functionality in existing tools

**For security questions:**
- Read `src/security.jl` for implementation
- Check `test/security_tests.jl` for examples
- Review security section in README.md

**For VS Code integration:**
- See `src/vscode.jl` for URI building and triggering
- Check `Generate.VSCODE_ALLOWED_COMMANDS` for allowed commands
- Review extended help for VS Code-related tools
