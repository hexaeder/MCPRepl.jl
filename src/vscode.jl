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
function install_vscode_remote_control(workspace_dir::AbstractString;
        publisher::AbstractString="MCPRepl",
        name::AbstractString="vscode-remote-control",
        version::AbstractString="0.0.1",
        allowed_commands::Vector{String} = [],
        require_confirmation::Bool = false)

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
                    rm(old_path; recursive=true, force=true)
                    println("Removed old extension: $entry")
                catch e
                    @warn "Could not remove old extension at $old_path" exception=e
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
          try {
            const query = new URLSearchParams(uri.query || "");
            const cmd = query.get('cmd') || '';
            const argsRaw = query.get('args');

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
                return;
              }
            }

            const cfg = vscode.workspace.getConfiguration('vscode-remote-control');
            const allowed = cfg.get('allowedCommands', []);
            const requireConfirmation = cfg.get('requireConfirmation', true);

            if (!allowed.includes(cmd)) {
              vscode.window.showErrorMessage('Remote Control: command not allowed: ' + cmd);
              return;
            }

            if (requireConfirmation) {
              const ok = await vscode.window.showWarningMessage(
                `Run command: ${cmd}${args.length ? ' with args' : ''}?`,
                { modal: true }, 'Run'
              );
              if (ok !== 'Run') return;
            }

            await vscode.commands.executeCommand(cmd, ...args);
          } catch (err) {
            vscode.window.showErrorMessage('Remote Control error: ' + err);
          }
        }
      };
      context.subscriptions.push(vscode.window.registerUriHandler(handler));
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
    # Merge workspace settings using JSON3
    existing = Dict{String,Any}()
    if isfile(ws_settings_path)
        try
            existing = JSON3.read(read(ws_settings_path, String), Dict{String,Any})
        catch e
            @warn "Could not parse existing workspace settings.json; will preserve it unchanged." exception=e
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
    
    # Write back with JSON3
    io_buf = IOBuffer()
    JSON3.pretty(io_buf, existing)
    json_str = String(take!(io_buf))
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