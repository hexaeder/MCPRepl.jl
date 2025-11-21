# MCPRepl.jl

I strongly believe that REPL-driven development is the best thing you can do in Julia, so AI Agents should learn it too!

MCPRepl.jl is a Julia package which exposes your REPL as an MCP server -- so that the agent can connect to it and execute code in your environment.
The code the Agent sends will show up in the REPL as well as your own commands. You're both working in the same state.


Ideally, this enables the Agent to, for example, execute and fix testsets interactively one by one, circumventing any time-to-first-plot issues.

## Showcase

https://github.com/user-attachments/assets/1c7546c4-23a3-4528-b222-fc8635af810d

## Installation

You can add the package using the Julia package manager:

```julia
pkg> add https://github.com/kahliburke/MCPRepl.jl
```
or for development:
```julia
pkg> dev https://github.com/kahliburke/MCPRepl.jl
```

## Usage

### First Time Setup

On first use, configure security settings:

```julia
julia> using MCPRepl
julia> MCPRepl.setup()  # Interactive setup wizard
```

### Starting the Server

Within Julia, call:
```julia
julia> using MCPRepl
julia> MCPRepl.start!()
```

This will start the MCP server using your configured security settings.

### Connecting from AI Clients

For Claude Desktop, you can run the following command to make it aware of the MCP server:

```sh
# With API key (strict/relaxed mode)
claude mcp add julia-repl http://localhost:3000 \
  --transport http \
  -H "Authorization: Bearer YOUR_API_KEY"

# Without API key (lax mode, localhost only)
claude mcp add julia-repl http://localhost:3000 --transport http
```

## Security

MCPRepl.jl includes a comprehensive security layer to protect your REPL from unauthorized access. The package requires security configuration before starting and offers three security modes:

### Security Modes

- **`:strict` (default)** - Requires API key authentication AND IP allowlist. Most secure option for production use.
- **`:relaxed`** - Requires API key authentication but accepts connections from any IP address.
- **`:lax`** - Localhost-only mode (127.0.0.1, ::1) with no API key required. Suitable for local development. This mode is borderline stupid for anything other than development on a trusted machine - use with caution.

### Initial Setup

On first run, MCPRepl will guide you through security setup:

```julia
julia> using MCPRepl
julia> MCPRepl.setup()  # Interactive setup wizard (dragon theme 🐉)

Prefer the gentle butterfly experience? Call setup with the keyword argument:

```julia
julia> MCPRepl.setup(; gentle=true)  # Gentle butterfly theme 🦋
```
**Prefer a gentler experience?** Use the butterfly theme instead:

Both wizards configure the same security options, just with different visual styles!

Or use quick setup for automation:

```julia
julia> MCPRepl.quick_setup(:lax)    # For local development
julia> MCPRepl.quick_setup(:strict) # For production
```

### Authentication

When using `:strict` or `:relaxed` modes, clients must include an API key in the Authorization header:

```bash
# Example with curl
curl -H "Authorization: Bearer mcprepl_YOUR_API_KEY_HERE" \
     http://localhost:3000
```

For AI clients like Claude, configure with your API key:

```sh
# Add server with authentication
claude mcp add julia-repl http://localhost:3000 \
  --transport http \
  -H "Authorization: Bearer mcprepl_YOUR_API_KEY_HERE"
```

### Security Management

MCPRepl provides helper functions to manage your security configuration:

```julia
# View current configuration
MCPRepl.security_status()

# Generate a new API key
MCPRepl.generate_key()

# Revoke an API key
MCPRepl.revoke_key("mcprepl_...")

# Add/remove IP addresses
MCPRepl.allow_ip("192.168.1.100")
MCPRepl.deny_ip("192.168.1.100")

# Change security mode
MCPRepl.set_security_mode(:relaxed)

# Reset configuration and start fresh
MCPRepl.reset()  # Removes all generated files
```

### Resetting Configuration

If you need to start fresh or completely remove MCPRepl configuration:

```julia
MCPRepl.reset()
```

This will remove:
- `.mcprepl/` directory (security config and API keys)
- `.julia-startup.jl` script
- VS Code Julia startup configuration
- MCP server entries from `.vscode/mcp.json`

After resetting, you can run `MCPRepl.setup()` again to reconfigure.

### Security Best Practices

- Use `:strict` mode for any production or remote deployment
- Regularly rotate API keys using `generate_key()` and `revoke_key()`
- Keep API keys secure - they grant full REPL access
- Review allowed IPs periodically with `security_status()`
- Use `:lax` mode only for local development on trusted machines

### Disclaimer

This software executes code sent to it over the network. While the security layer protects against unauthorized access, you should still:

- Only use this on machines where you understand the security implications
- Keep your API keys confidential
- Monitor active connections and revoke compromised keys immediately
- Use firewall rules as an additional layer of defense

This software is provided "as is" without warranties. Use at your own risk.

## LSP Integration

MCPRepl.jl includes Language Server Protocol (LSP) integration, giving AI agents access to code navigation and refactoring capabilities. These tools enable intelligent code analysis without requiring interactive GUI features.

### Available LSP Tools

**Navigation & Analysis:**
- **`lsp_goto_definition`** — Jump to where a function, type, or variable is defined
- **`lsp_find_references`** — Find all usages of a symbol throughout the codebase
- **`lsp_document_symbols`** — Get outline/structure of a file (all functions, types, etc.)
- **`lsp_workspace_symbols`** — Search for symbols across the entire workspace

**Refactoring & Formatting:**
- **`lsp_rename`** — Safely rename a symbol across the entire workspace
- **`lsp_code_actions`** — Get available quick fixes and refactorings for errors/warnings
- **`lsp_format_document`** — Format an entire Julia file
- **`lsp_format_range`** — Format only specific lines of code

> **Note for AI Agents:** For documentation and type information, use Julia's built-in introspection in the REPL:
> - `@doc function_name` — Get documentation
> - `methods(function_name)` — See all method signatures
> - `?function_name` — Interactive help

### Example Usage

```julia
# Find where a function is defined
lsp_goto_definition(
    file_path = "/path/to/file.jl",
    line = 42,
    column = 10
)

# Find all usages of a function
lsp_find_references(
    file_path = "/path/to/file.jl",
    line = 42,
    column = 10
)

# Rename a symbol across the entire codebase
lsp_rename(
    file_path = "/path/to/file.jl",
    line = 42,
    column = 10,
    new_name = "better_function_name"
)

# Get available quick fixes for an error
lsp_code_actions(
    file_path = "/path/to/file.jl",
    start_line = 42,
    start_column = 10
)
```

```

### AI Agent Benefits

The LSP integration enables AI agents to:

- **Navigate code intelligently** — Jump to definitions and find usages instead of searching text
- **Refactor safely** — Use rename to change symbols across the entire codebase
- **Fix errors automatically** — Get code actions for quick fixes and suggested improvements
- **Format consistently** — Apply standard formatting to code
- **Discover structure** — Get document outlines and search for symbols workspace-wide

All LSP operations use the Julia Language Server already running in VS Code, ensuring accurate results.

> **Tip:** For documentation and type introspection, agents should use the REPL directly (`@doc`, `methods()`, `fieldnames()`, etc.) rather than LSP tools, as this provides richer information and context.

## Using in Other Projects

MCPRepl can be used as a dependency in your own Julia projects. The package includes:

### Proxy Server
Start a persistent MCP proxy that routes requests to REPL backends:

```julia
using MCPRepl

# Start proxy (auto-starts dashboard in development mode)
MCPRepl.start_proxy(port=3000)

# Or use the CLI
# julia proxy.jl start --background
```

The proxy provides:
- **Persistent endpoint** - Stays up even when REPL backends restart
- **Dashboard** - Web UI at `http://localhost:3000/dashboard` for monitoring
- **Session routing** - Route requests to specific REPL instances
- **Zero-downtime** - REPL can restart without breaking client connections

### Dashboard

The dashboard is automatically available when the proxy is running:
- **Development**: Auto-starts Vite dev server with hot reload
- **Production**: Serves pre-built static files (no Node.js required)

Access at: `http://localhost:3000/dashboard`

### Programmatic Usage

```julia
using MCPRepl

# Start a REPL backend
MCPRepl.start!(port=4000)

# In another project, connect to the proxy
# Your AI agent connects to port 3000 (proxy)
# Proxy forwards to port 4000 (your REPL)
```

## Similar Packages
- [ModelContexProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) offers a way of defining your own servers. Since MCPRepl is using a HTTP server I decieded to not go with this package.

- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) is very similar, but the focus of MCPRepl.jl is to integrate with the user repl so you can see what your agent is doing.
