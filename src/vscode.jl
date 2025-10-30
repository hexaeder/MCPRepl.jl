# ========== VS Code Remote Control: create, install, and configure (workspace) ==========

"""
    install_vscode_remote_control(workspace_dir; publisher="your-publisher-id",
                                  name="vscode-remote-control", version="0.0.1",
                                  allowed_commands=["workbench.action.files.save"],
                                  require_confirmation=false)

Creates a minimal VS Code extension that exposes a `vscode://` URI handler, installs it
(by copying into the user's VS Code extensions dir), and updates the given workspace's
`.vscode/settings.json` to allow the specified command IDs and (optionally) disable the
confirmation prompt.

Usage:
    install_vscode_remote_control(pwd(); allowed_commands=[
        "language-julia.restartREPL",
        "language-julia.startREPL",
        "workbench.action.reloadWindow",
        "workbench.action.files.save",
    ])
"""
function install_vscode_remote_control(
    workspace_dir::AbstractString;
    publisher::AbstractString = "MCPRepl",
    name::AbstractString = "vscode-remote-control",
    version::AbstractString = "0.0.1",
    allowed_commands::Vector{String} = String[],
    require_confirmation::Bool = false,
)

    # -------------------------------- paths --------------------------------
    ext_folder_name = "$(publisher).$(name)-$(version)"
    exts_dir = vscode_extensions_dir()
    ext_path = joinpath(exts_dir, ext_folder_name)
    src_path = joinpath(ext_path, "out")
    workspace_dir = abspath(workspace_dir)
    ws_vscode = joinpath(workspace_dir, ".vscode")
    ws_settings_path = joinpath(ws_vscode, "settings.json")

    # Remove old extension versions if they exist
    if isdir(exts_dir)
        for entry in readdir(exts_dir)
            # Match any version of this extension
            if startswith(entry, "$(publisher).$(name)-")
                old_path = joinpath(exts_dir, entry)
                try
                    rm(old_path; recursive = true, force = true)
                    println("Removed old extension: $entry")
                catch e
                    @warn "Could not remove old extension at $old_path" exception = e
                end
            end
        end
    end

    mkpath(src_path)
    mkpath(ws_vscode)

    # --------------------------- write package.json -------------------------
    pkgjson = """
    {
      "name": "$(name)",
      "displayName": "VS Code Remote Control",
      "description": "Execute allowlisted VS Code commands via vscode:// URI",
      "version": "$(version)",
      "publisher": "$(publisher)",
      "engines": { "vscode": "^1.85.0" },
      "activationEvents": ["onUri"],
      "main": "./out/extension.js",
      "contributes": {
        "configuration": {
          "type": "object",
          "title": "Remote Control",
          "properties": {
            "vscode-remote-control.allowedCommands": {
              "type": "array",
              "default": ["workbench.action.files.save"],
              "description": "Command IDs this extension may run."
            },
            "vscode-remote-control.requireConfirmation": {
              "type": "boolean",
              "default": true,
              "description": "Ask before executing a command."
            }
          }
        }
      }
    }
    """
    open(joinpath(ext_path, "package.json"), "w") do io
        write(io, pkgjson)
    end

    # --------------------------- write extension.js -------------------------
    # Plain CommonJS; no build step required.
    extjs = raw"""
    const vscode = require('vscode');

    function activate(context) {
      const handler = {
        async handleUri(uri) {
          let requestId = null;
          let mcpPort = 3000;  // Default MCP server port
          
          try {
            const query = new URLSearchParams(uri.query || "");
            const cmd = query.get('cmd') || '';
            const argsRaw = query.get('args');
            requestId = query.get('request_id');
            const portRaw = query.get('mcp_port');
            
            if (portRaw) {
              mcpPort = parseInt(portRaw, 10);
            }

            if (!cmd) {
              vscode.window.showErrorMessage('Remote Control: missing "cmd".');
              return;
            }

            let args = [];
            if (argsRaw) {
              try {
                const decoded = decodeURIComponent(argsRaw);
                const parsed = JSON.parse(decoded);
                args = Array.isArray(parsed) ? parsed : [parsed];
              } catch (e) {
                vscode.window.showErrorMessage('Remote Control: invalid args JSON: ' + e);
                await sendResponse(mcpPort, requestId, null, 'Failed to parse args: ' + e);
                return;
              }
            }

            const cfg = vscode.workspace.getConfiguration('vscode-remote-control');
            const allowed = cfg.get('allowedCommands', []);
            const requireConfirmation = cfg.get('requireConfirmation', true);

            if (!allowed.includes(cmd)) {
              const msg = 'Remote Control: command not allowed: ' + cmd;
              vscode.window.showErrorMessage(msg);
              await sendResponse(mcpPort, requestId, null, msg);
              return;
            }

            if (requireConfirmation) {
              const ok = await vscode.window.showWarningMessage(
                `Run command: ${cmd}${args.length ? ' with args' : ''}?`,
                { modal: true }, 'Run'
              );
              if (ok !== 'Run') {
                await sendResponse(mcpPort, requestId, null, 'User cancelled command');
                return;
              }
            }

            // Convert file:// URI strings to vscode.Uri objects for LSP commands
            const convertedArgs = args.map(arg => {
              if (typeof arg === 'string' && arg.startsWith('file://')) {
                return vscode.Uri.parse(arg);
              }
              return arg;
            });

            // Execute command and capture result
            const result = await vscode.commands.executeCommand(cmd, ...convertedArgs);
            
            // Send result back to MCP server if request_id was provided
            await sendResponse(mcpPort, requestId, result, null);
            
          } catch (err) {
            vscode.window.showErrorMessage('Remote Control error: ' + err);
            await sendResponse(mcpPort, requestId, null, String(err));
          }
        }
      };
      context.subscriptions.push(vscode.window.registerUriHandler(handler));
    }

    // Helper function to send response back to MCP server
    async function sendResponse(port, requestId, result, error) {
      // Only send if requestId was provided (indicates caller wants response)
      if (!requestId) return;
      
      try {
        const http = require('http');
        const fs = require('fs');
        const path = require('path');
        
        const payload = JSON.stringify({
          request_id: requestId,
          result: result,
          error: error,
          timestamp: Date.now()
        });
        
        // Try to read Authorization header and port from .vscode/mcp.json
        let authHeader = null;
        let mcpConfigPort = null;
        try {
          const workspaceFolders = vscode.workspace.workspaceFolders;
          if (workspaceFolders && workspaceFolders.length > 0) {
            const mcpConfigPath = path.join(workspaceFolders[0].uri.fsPath, '.vscode', 'mcp.json');
            if (fs.existsSync(mcpConfigPath)) {
              const mcpConfig = JSON.parse(fs.readFileSync(mcpConfigPath, 'utf8'));
              if (mcpConfig.servers && mcpConfig.servers['julia-repl']) {
                const juliaServer = mcpConfig.servers['julia-repl'];
                
                // Extract port from URL
                if (juliaServer.url) {
                  const urlMatch = juliaServer.url.match(/localhost:(\d+)/);
                  if (urlMatch) {
                    mcpConfigPort = parseInt(urlMatch[1], 10);
                  }
                }
                
                // Extract Authorization header
                if (juliaServer.headers && juliaServer.headers.Authorization) {
                  authHeader = juliaServer.headers.Authorization;
                  
                  // Resolve VS Code environment variable syntax: ${env:VAR_NAME}
                  const envVarMatch = authHeader.match(/\$\{env:([^}]+)\}/);
                  if (envVarMatch) {
                    const envVarName = envVarMatch[1];
                    const envValue = process.env[envVarName];
                    if (envValue) {
                      authHeader = authHeader.replace(envVarMatch[0], envValue);
                    } else {
                      console.warn(`Environment variable ${envVarName} not found`);
                      authHeader = null;
                    }
                  }
                }
              }
            }
          }
        } catch (e) {
          console.error('Could not read mcp.json:', e);
        }
        
        // Use port from mcp.json if not provided via URI, or try .mcprepl/security.json
        if (!port || port === 3000) {
          if (mcpConfigPort) {
            port = mcpConfigPort;
          } else {
            // Try to read from .mcprepl/security.json as last resort
            try {
              const workspaceFolders = vscode.workspace.workspaceFolders;
              if (workspaceFolders && workspaceFolders.length > 0) {
                const securityPath = path.join(workspaceFolders[0].uri.fsPath, '.mcprepl', 'security.json');
                if (fs.existsSync(securityPath)) {
                  const securityConfig = JSON.parse(fs.readFileSync(securityPath, 'utf8'));
                  if (securityConfig.port) {
                    port = securityConfig.port;
                  }
                }
              }
            } catch (e) {
              console.error('Could not read .mcprepl/security.json:', e);
            }
          }
        }
        
        const headers = {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload)
        };
        
        // Add Authorization header if found
        if (authHeader) {
          headers['Authorization'] = authHeader;
        }
        
        const options = {
          hostname: 'localhost',
          port: port,
          path: '/vscode-response',
          method: 'POST',
          headers: headers
        };
        
        const req = http.request(options, (res) => {
          // Consume response data to free up memory
          res.on('data', () => {});
        });
        
        req.on('error', (err) => {
          console.error('Failed to send response to MCP server:', err);
        });
        
        req.write(payload);
        req.end();
      } catch (e) {
        console.error('Error in sendResponse:', e);
      }
    }

    function deactivate() {}

    module.exports = { activate, deactivate };
    """
    open(joinpath(src_path, "extension.js"), "w") do io
        write(io, extjs)
    end

    # ------------------------ write a basic README.md -----------------------
    readme = """
    # VS Code Remote Control

    Use \`vscode://$(publisher).$(name)?cmd=COMMAND_ID&args=JSON_ENCODED_ARGS\`
    to execute allowlisted commands. Configure allowed commands in settings:
    \`vscode-remote-control.allowedCommands\`.
    """
    open(joinpath(ext_path, "README.md"), "w") do io
        write(io, readme)
    end

    # ----------------------------- settings.json ----------------------------
    # Merge workspace settings using JSON
    existing = Dict{String,Any}()
    if isfile(ws_settings_path)
        try
            existing =
                JSON.parse(read(ws_settings_path, String); dicttype = Dict{String,Any})
        catch e
            @warn "Could not parse existing workspace settings.json; will preserve it unchanged." exception =
                e
        end
    end

    # Merge our keys
    ns = "vscode-remote-control"
    key_allowed = "$ns.allowedCommands"
    key_confirm = "$ns.requireConfirmation"

    # Merge allowed commands (union with existing)
    allowed_set = Set{String}(get(existing, key_allowed, String[]))
    union!(allowed_set, allowed_commands)
    existing[key_allowed] = sort(collect(allowed_set))
    existing[key_confirm] = require_confirmation

    # Write back with pretty-printed JSON (2-space indentation)
    json_str = JSON.json(existing, 2)
    write(ws_settings_path, json_str)

    println("Installed extension into: ", ext_path)
    println("Workspace settings updated at: ", ws_settings_path)
    println("Now you can call, e.g.:")
    println("  open(\"vscode://$(publisher).$(name)?cmd=workbench.action.reloadWindow\")")

    return ext_path
end

# ------------------------ helpers: paths ------------------------

function vscode_extensions_dir()
    # Default per-user extensions dir used by VS Code
    home = homedir()
    if Sys.iswindows()
        # %USERPROFILE%\.vscode\extensions
        return joinpath(get(ENV, "USERPROFILE", home), ".vscode", "extensions")
    else
        # macOS & Linux
        return joinpath(home, ".vscode", "extensions")
    end
end
