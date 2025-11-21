# ============================================================================
# Security Module - API Key Authentication and IP Allowlisting
# ============================================================================

using Random
using SHA
using JSON
using TOML

# Security configuration structure
struct SecurityConfig
    mode::Symbol  # :strict, :relaxed, or :lax
    api_keys::Vector{String}
    allowed_ips::Vector{String}
    port::Int
    created_at::Int64
end

function SecurityConfig(
    mode::Symbol,
    api_keys::Vector{String},
    allowed_ips::Vector{String},
    port::Int=3000,
)
    return SecurityConfig(mode, api_keys, allowed_ips, port, Int64(round(time())))
end

"""
    generate_api_key() -> String

Generate a cryptographically secure API key.
Format: mcprepl_<40 hex characters>
"""
function generate_api_key()
    # Generate 20 random bytes (160 bits)
    random_bytes = rand(UInt8, 20)
    # Convert to hex string
    hex_string = bytes2hex(random_bytes)
    return "mcprepl_" * hex_string
end

"""
    get_security_config_path(workspace_dir::String=pwd()) -> String

Get the path to the security configuration file for a workspace.
"""
function get_security_config_path(workspace_dir::String=pwd())
    config_dir = joinpath(workspace_dir, ".mcprepl")
    return joinpath(config_dir, "security.json")
end

"""
    load_security_config(workspace_dir::String=pwd(), agent_name::String="", supervisor::Bool=false) -> Union{SecurityConfig, Nothing}

Load security configuration from workspace .mcprepl/security.json file.
Returns nothing if no configuration exists.

If port is not specified in configuration, defaults to 0 (dynamic port assignment in 40000-49999 range).
"""
function load_security_config(
    workspace_dir::String=pwd(),
    agent_name::String="",
    supervisor::Bool=false,
)
    config_path = get_security_config_path(workspace_dir)

    # Try to load from agents.json if in agent or supervisor mode
    agents_config_path = joinpath(workspace_dir, ".mcprepl", "agents.json")

    # If agent mode, ALWAYS use agents.json (never security.json)
    if !isempty(agent_name)
        if isfile(agents_config_path)
            try
                agents_config = JSON.parsefile(agents_config_path)
                if haskey(agents_config, "agents") &&
                   haskey(agents_config["agents"], agent_name)
                    agent_config = agents_config["agents"][agent_name]

                    mode = Symbol(get(agent_config, "mode", "lax"))
                    api_keys = get(agent_config, "api_keys", String[])
                    allowed_ips = get(agent_config, "allowed_ips", String[])
                    # Port defaults to 0 (dynamic assignment) if not specified
                    port = get(agent_config, "port", 0)
                    created_at = Int64(round(time()))

                    @info "Loaded security config for agent from agents.json" agent =
                        agent_name mode = mode port = port path = agents_config_path
                    return SecurityConfig(mode, api_keys, allowed_ips, port, created_at)
                else
                    # Agent not in agents.json - fall back to lax mode with warning
                    available = collect(keys(get(agents_config, "agents", Dict())))
                    @warn "Agent '$agent_name' not found in agents.json" path = agents_config_path available = available fallback = "lax mode with dynamic port"
                    created_at = Int64(round(time()))
                    return SecurityConfig(:lax, String[], String[], 0, created_at)
                end
            catch e
                if e isa ErrorException && contains(e.msg, "not found in agents.json")
                    rethrow(e)  # Re-throw our specific error
                end
                error("Failed to load agent config from agents.json: $e")
            end
        else
            # No agents.json found - fall back to lax mode with warning
            @warn "Agents config file not found for agent '$agent_name'" path = agents_config_path fallback = "lax mode with dynamic port"
            created_at = Int64(round(time()))
            return SecurityConfig(:lax, String[], String[], 0, created_at)
        end
    end

    # If supervisor mode, ALWAYS use agents.json (never security.json)
    if supervisor
        if isfile(agents_config_path)
            try
                agents_config = JSON.parsefile(agents_config_path)
                if haskey(agents_config, "supervisor")
                    supervisor_config = agents_config["supervisor"]

                    mode = Symbol(get(supervisor_config, "mode", "lax"))
                    api_keys = get(supervisor_config, "api_keys", String[])
                    allowed_ips = get(supervisor_config, "allowed_ips", String[])
                    # Port defaults to 0 (dynamic assignment) if not specified
                    port = get(supervisor_config, "port", 0)
                    created_at = Int64(round(time()))

                    @info "Loaded security config for supervisor from agents.json" mode =
                        mode port = port path = agents_config_path
                    return SecurityConfig(mode, api_keys, allowed_ips, port, created_at)
                else
                    error(
                        "Supervisor config not found in agents.json at $agents_config_path",
                    )
                end
            catch e
                if e isa ErrorException && contains(e.msg, "Supervisor config not found")
                    rethrow(e)  # Re-throw our specific error
                end
                error("Failed to load supervisor config from agents.json: $e")
            end
        else
            error("Agents config file not found for supervisor at $agents_config_path")
        end
    end

    if !isfile(config_path)
        return nothing
    end

    try
        content = read(config_path, String)
        data = JSON.parse(content; dicttype=Dict{String,Any})

        mode = Symbol(get(data, "mode", "strict"))
        api_keys = get(data, "api_keys", String[])
        allowed_ips = get(data, "allowed_ips", ["127.0.0.1", "::1"])
        port = get(data, "port", 0)  # Default to 0 (dynamic port assignment)
        created_at = get(data, "created_at", time())

        return SecurityConfig(mode, api_keys, allowed_ips, port, created_at)
    catch e
        @warn "Failed to load security config" exception = e
        return nothing
    end
end

"""
    save_security_config(config::SecurityConfig, workspace_dir::String=pwd()) -> Bool

Save security configuration to workspace .mcprepl/security.json file.
"""
function save_security_config(config::SecurityConfig, workspace_dir::String=pwd())
    config_path = get_security_config_path(workspace_dir)
    config_dir = dirname(config_path)

    # Create .mcprepl directory if it doesn't exist
    if !isdir(config_dir)
        mkpath(config_dir)
    end

    # Add .mcprepl to .gitignore if not already present
    gitignore_path = joinpath(workspace_dir, ".gitignore")
    if isfile(gitignore_path)
        gitignore_content = read(gitignore_path, String)
        if !contains(gitignore_content, ".mcprepl")
            open(gitignore_path, "a") do io
                println(io, "\n# MCPRepl security configuration (contains API keys)")
                println(io, ".mcprepl/")
            end
        end
    else
        # Create .gitignore with .mcprepl
        open(gitignore_path, "w") do io
            println(io, "# MCPRepl security configuration (contains API keys)")
            println(io, ".mcprepl/")
        end
    end

    try
        data = Dict(
            "mode" => string(config.mode),
            "api_keys" => config.api_keys,
            "allowed_ips" => config.allowed_ips,
            "port" => config.port,
            "created_at" => config.created_at,
        )

        # Pretty print JSON with indentation
        json_str = JSON.json(data, 2)  # 2 spaces indentation
        write(config_path, json_str)

        # Set restrictive permissions on config file (Unix-like systems)
        if !Sys.iswindows()
            chmod(config_path, 0o600)  # Read/write for owner only
        end

        return true
    catch e
        @warn "Failed to save security config" exception = e
        return false
    end
end

"""
    validate_api_key(key::String, config::SecurityConfig) -> Bool

Validate an API key against the security configuration.
"""
function validate_api_key(key::String, config::SecurityConfig)
    # In :lax mode, no API key required
    if config.mode == :lax
        return true
    end

    return key in config.api_keys
end

"""
    validate_ip(ip::String, config::SecurityConfig) -> Bool

Validate an IP address against the allowlist.
"""
function validate_ip(ip::String, config::SecurityConfig)
    # In :relaxed mode, skip IP validation
    if config.mode == :relaxed
        return true
    end

    # In :lax mode, only allow localhost
    if config.mode == :lax
        return ip in ["127.0.0.1", "::1", "localhost"]
    end

    # In :strict mode, check against allowlist
    return ip in config.allowed_ips
end

"""
    extract_api_key(req::HTTP.Request) -> Union{String, Nothing}

Extract API key from Authorization header.
Supports: "Bearer <key>" or just "<key>"
"""
function extract_api_key(req)
    for (name, value) in req.headers
        if lowercase(name) == "authorization"
            # Remove "Bearer " prefix if present
            if startswith(value, "Bearer ")
                return value[8:end]
            else
                return value
            end
        end
    end
    return nothing
end

"""
    get_client_ip(req::HTTP.Request) -> String

Extract client IP address from request.
Checks X-Forwarded-For header first, then falls back to peer address.
"""
function get_client_ip(req)
    # Check X-Forwarded-For header (for proxies)
    for (name, value) in req.headers
        if lowercase(name) == "x-forwarded-for"
            # Take the first IP in the list
            return strip(split(value, ",")[1])
        end
    end

    # Fall back to direct connection IP (if available)
    # HTTP.jl doesn't always expose this easily, so default to localhost
    return "127.0.0.1"
end

"""
    show_security_status(config::SecurityConfig)

Display current security configuration in a readable format.
"""
function show_security_status(config::SecurityConfig)
    println()
    println("🔒 Security Configuration")
    println("="^50)
    println()
    println("Mode: ", config.mode)
    println("  • :strict  - API key + IP allowlist required")
    println("  • :relaxed - API key required, any IP allowed")
    println("  • :lax     - Localhost only, no API key")
    println()
    println("API Keys: ", length(config.api_keys))
    for (i, key) in enumerate(config.api_keys)
        masked_key = key[1:min(15, length(key))] * "..." * key[max(1, end - 3):end]
        println("  $i. $masked_key")
    end
    println()
    println("Allowed IPs: ", length(config.allowed_ips))
    for ip in config.allowed_ips
        println("  • $ip")
    end
    println()
    println("Created: ", Dates.unix2datetime(config.created_at))
    println()
end

"""
    add_api_key!(workspace_dir::String=pwd()) -> String

Generate and add a new API key to the security configuration.
Returns the new key.
"""
function add_api_key!(workspace_dir::String=pwd())
    config = load_security_config(workspace_dir)
    if config === nothing
        error("No security configuration found. Run MCPRepl.setup() first.")
    end

    new_key = generate_api_key()
    new_config = SecurityConfig(
        config.mode,
        vcat(config.api_keys, [new_key]),
        config.allowed_ips,
        config.port,
        config.created_at,
    )

    if save_security_config(new_config, workspace_dir)
        println("✅ Added new API key: $new_key")
        println("⚠️  Save this key securely - it won't be shown again!")
        return new_key
    else
        error("Failed to save security configuration")
    end
end

"""
    remove_api_key!(key::String, workspace_dir::String=pwd()) -> Bool

Remove an API key from the security configuration.
"""
function remove_api_key!(key::String, workspace_dir::String=pwd())
    config = load_security_config(workspace_dir)
    if config === nothing
        error("No security configuration found. Run MCPRepl.setup() first.")
    end

    if !(key in config.api_keys)
        @warn "API key not found in configuration"
        return false
    end

    new_keys = filter(k -> k != key, config.api_keys)
    new_config = SecurityConfig(
        config.mode,
        new_keys,
        config.allowed_ips,
        config.port,
        config.created_at,
    )

    if save_security_config(new_config, workspace_dir)
        println("✅ Removed API key")
        return true
    else
        error("Failed to save security configuration")
    end
end

"""
    add_allowed_ip!(ip::String, workspace_dir::String=pwd()) -> Bool

Add an IP address to the allowlist.
"""
function add_allowed_ip!(ip::String, workspace_dir::String=pwd())
    config = load_security_config(workspace_dir)
    if config === nothing
        error("No security configuration found. Run MCPRepl.setup() first.")
    end

    if ip in config.allowed_ips
        @warn "IP address already in allowlist"
        return false
    end

    new_ips = vcat(config.allowed_ips, [ip])
    new_config = SecurityConfig(
        config.mode,
        config.api_keys,
        new_ips,
        config.port,
        config.created_at,
    )

    if save_security_config(new_config, workspace_dir)
        println("✅ Added IP address to allowlist: $ip")
        return true
    else
        error("Failed to save security configuration")
    end
end

"""
    remove_allowed_ip!(ip::String, workspace_dir::String=pwd()) -> Bool

Remove an IP address from the allowlist.
"""
function remove_allowed_ip!(ip::String, workspace_dir::String=pwd())
    config = load_security_config(workspace_dir)
    if config === nothing
        error("No security configuration found. Run MCPRepl.setup() first.")
    end

    if !(ip in config.allowed_ips)
        @warn "IP address not found in allowlist"
        return false
    end

    new_ips = filter(i -> i != ip, config.allowed_ips)
    new_config = SecurityConfig(
        config.mode,
        config.api_keys,
        new_ips,
        config.port,
        config.created_at,
    )

    if save_security_config(new_config, workspace_dir)
        println("✅ Removed IP address from allowlist: $ip")
        return true
    else
        error("Failed to save security configuration")
    end
end

"""
    change_security_mode!(mode::Symbol, workspace_dir::String=pwd()) -> Bool

Change the security mode (:strict, :relaxed, or :lax).
"""
function change_security_mode!(mode::Symbol, workspace_dir::String=pwd())
    if !(mode in [:strict, :relaxed, :lax])
        error("Invalid security mode. Must be :strict, :relaxed, or :lax")
    end

    config = load_security_config(workspace_dir)
    if config === nothing
        error("No security configuration found. Run MCPRepl.setup() first.")
    end

    new_config = SecurityConfig(
        mode,
        config.api_keys,
        config.allowed_ips,
        config.port,
        config.created_at,
    )

    if save_security_config(new_config, workspace_dir)
        println("✅ Changed security mode to: $mode")
        return true
    else
        error("Failed to save security configuration")
    end
end
