# MCPRepl.jl

MCPRepl.jl is a Julia package which exposes your REPL as an MCP server -- so that coding can connect to it and execute code in your environment.
I strongly believe that REPL driven development is the best thing you can do in Julia, so the Agents should learn it to.


## Installation

This package is not registered in the official Julia General registry due to the security implications of its use. To install it, you must do so directly from the source repository.

You can add the package using the Julia package manager:

```julia
pkg> add https://github.com/your-username/MCPRepl.jl
```
or
```julia
pkg> dev https://github.com/your-username/MCPRepl.jl
```

## Usage
Within Julia, call
``` julia-repl
julia> using MCPRepl; MCPRepl.start!()
```
to open the HTTP endpoints.

For claude code, you can run the follwing command to make it aware of the MCP server
```sh
claude mcp add julia-repl http://localhost:3000 --transport http
```

## Disclaimer and Security Warning

The core functionality of MCPRepl.jl involves opening a network port and executing any code that is sent to it. This is inherently dangerous and borderline stupid, but thats how it is in the great new world of coding agents.

By using this software, you acknowledge and accept the following:

*   **Risk of Arbitrary Code Execution:** Anyone who can connect to the open port will be able to execute arbitrary code on the host machine with the same privileges as the Julia process.
*   **No Warranties:** This software is provided "as is" without any warranties of any kind. The developers are not responsible for any damage, data loss, or other security breaches that may result from its use.

It is strongly recommended that you only use this package on isolated systems or networks where you have complete control over who can access the port. **Use at your own risk.**
