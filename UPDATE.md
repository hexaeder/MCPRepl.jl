# Updating MCPRepl

If you installed MCPRepl using `Pkg.add("https://github.com/kahliburke/MCPRepl.jl")`, follow these steps to get the latest updates:

## Update Instructions

1. **Update the package:**
   ```julia
   using Pkg
   Pkg.update("MCPRepl")
   ```

2. **Restart your Julia REPL** to load the new code.

3. **Test the installation:**
   ```julia
   using MCPRepl
   
   # Check that MCPRepl loads without errors
   println("✓ MCPRepl loaded successfully")
   
   # Optional: Run the setup to verify everything works
   # MCPRepl.setup()
   ```

## Troubleshooting

If you encounter issues after updating:

1. **Force a clean update:**
   ```julia
   using Pkg
   Pkg.update("MCPRepl")
   Pkg.resolve()
   ```

2. **Check the installed version:**
   ```julia
   using Pkg
   Pkg.status("MCPRepl")
   ```

3. **If problems persist, reinstall:**
   ```julia
   using Pkg
   Pkg.rm("MCPRepl")
   Pkg.add("https://github.com/kahliburke/MCPRepl.jl")
   ```

## Getting Help

If you continue to have issues, please open an issue at:
https://github.com/kahliburke/MCPRepl.jl/issues
