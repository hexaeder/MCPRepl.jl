# ============================================================================
# Security Setup Wizard - Dramatic Edition 🐉
# ============================================================================

using Printf

const DRAGON_ASCII = raw"""
                                                     __----~~~~~~~~~~~------___
                                    .  .   ~~//====......          __--~ ~~
                    -.            \_|//     |||\\  ~~~~~~::::... /~
                 ___-==_       _-~o~  \/    |||  \\            _/~~-
         __---~~~.==~||\=_    -_--~/_-~|-   |\\   \\        _/~
     _-~~     .=~    |  \\-_    '-~7  /-   /  ||    \      /
   .~       .~       |   \\ -_    /  /-   /   ||      \   /
  /  ____  /         |     \\ ~-_/  /|- _/   .||       \ /
  |~~    ~~|--~~~~--_ \     ~==-/   | \~--===~~        .\
           '         ~-|      /|    |-~\~~       __--~~
                       |-~~-_/ |    |   ~\_   _-~            /\
                            /  \     \__   \/~                \__
                        _--~ _/ | .-~~____--~-/                  ~~==.
                       ((->/~   '.|||' -_|    ~~-/ ,              . _||
                                  -_     ~\      ~~---l__i__i__i--~~_/
                                  _-~-__   ~)  \--______________--~~
                                //.-~~~-~_--~- |-------~~~~~~~~
                                       //.-~~~--\

            ⚠️  DANGER ZONE: YOU ARE ABOUT TO UNLEASH REMOTE CODE EXECUTION ⚠️
"""

const FLAMES = ["🔥", "💥", "⚡", "💀", "☠️", "⚠️"]

"""
    animate_text(text::String, delay::Float64=0.02)

Print text with a typing animation effect.
"""
function animate_text(text::String, delay::Float64 = 0.02)
    for char in text
        print(char)
        flush(stdout)
        sleep(delay)
    end
    println()
end

"""
    flash_warning(times::Int=3)

Flash warning symbols to get attention.
"""
function flash_warning(times::Int = 3)
    for _ = 1:times
        for flame in FLAMES
            print("\r" * " "^80)  # Clear line
            print("\r" * flame^40)
            flush(stdout)
            sleep(0.1)
        end
    end
    print("\r" * " "^80 * "\r")  # Clear line
    flush(stdout)
end

"""
    security_setup_wizard(workspace_dir::String=pwd(); force::Bool=false) -> SecurityConfig

Launch the dramatic security setup wizard.
Force explicit acknowledgment of security risks before generating configuration.
"""
function security_setup_wizard(workspace_dir::String = pwd(); force::Bool = false)
    # Check if config already exists
    existing_config = load_security_config(workspace_dir)
    if existing_config !== nothing && !force
        println()
        printstyled("✅ Security configuration already exists\n", color = :green, bold = true)
        println()
        show_security_status(existing_config)
        println()
        print("Reconfigure security? This will invalidate existing API keys. [y/N]: ")
        response = strip(lowercase(readline()))
        if !(response == "y" || response == "yes")
            return existing_config
        end
        println()
    end

    # Display the dragon and warning
    printstyled(DRAGON_ASCII, color = :red, bold = true)
    println()

    # Flash warnings
    flash_warning(2)

    println()
    printstyled(
        "╔═══════════════════════════════════════════════════════════════════╗\n",
        color = :yellow,
        bold = true,
    )
    printstyled(
        "║                                                                   ║\n",
        color = :yellow,
        bold = true,
    )
    printstyled(
        "║     YOU ARE CONFIGURING A REMOTE CODE EXECUTION SERVER           ║\n",
        color = :red,
        bold = true,
    )
    printstyled(
        "║                                                                   ║\n",
        color = :yellow,
        bold = true,
    )
    printstyled(
        "║  This server will execute ANY code sent to it by authenticated   ║\n",
        color = :white,
    )
    printstyled(
        "║  clients. While MCPRepl includes security features, it is still  ║\n",
        color = :white,
    )
    printstyled(
        "║  fundamentally a powerful and potentially dangerous tool.        ║\n",
        color = :white,
    )
    printstyled(
        "║                                                                   ║\n",
        color = :yellow,
        bold = true,
    )
    printstyled(
        "║  YOU MUST:                                                        ║\n",
        color = :cyan,
        bold = true,
    )
    printstyled(
        "║    • Keep API keys secret and secure                             ║\n",
        color = :white,
    )
    printstyled(
        "║    • Never commit .mcprepl/ directory to version control         ║\n",
        color = :white,
    )
    printstyled(
        "║    • Only allow trusted IPs in production environments           ║\n",
        color = :white,
    )
    printstyled(
        "║    • Understand that API keys grant FULL code execution rights   ║\n",
        color = :white,
    )
    printstyled(
        "║    • Take responsibility for any code executed through this      ║\n",
        color = :white,
    )
    printstyled(
        "║                                                                   ║\n",
        color = :yellow,
        bold = true,
    )
    printstyled(
        "╚═══════════════════════════════════════════════════════════════════╝\n",
        color = :yellow,
        bold = true,
    )
    println()

    # Force explicit acknowledgment
    printstyled(
        "Type 'I UNDERSTAND THE RISKS' to continue: ",
        color = :red,
        bold = true,
    )
    acknowledgment = strip(readline())

    if acknowledgment != "I UNDERSTAND THE RISKS"
        println()
        printstyled("❌ Setup cancelled. Safety first! 🛡️\n", color = :green, bold = true)
        println()
        error("Security setup cancelled by user")
    end

    println()
    printstyled("✅ Acknowledgment accepted. Proceeding with setup...\n", color = :green)
    println()
    sleep(0.5)

    # Choose security mode
    printstyled("🔐 Choose Security Mode\n", color = :cyan, bold = true)
    println()
    println("  [1] 🔒 STRICT   - API key required + IP allowlist enforced")
    println("                   (Recommended for production)")
    println()
    println("  [2] 🔓 RELAXED  - API key required + any IP allowed")
    println("                   (Useful for dynamic IPs, but less secure)")
    println()
    println("  [3] 🏠 LAX      - Localhost only + no API key required")
    println("                   (Quick local development, localhost only)")
    println()

    mode_choice = nothing
    while mode_choice === nothing
        print("Select mode [1/2/3] (default: 1): ")
        choice = strip(readline())

        if isempty(choice)
            mode_choice = :strict
        elseif choice == "1"
            mode_choice = :strict
        elseif choice == "2"
            mode_choice = :relaxed
        elseif choice == "3"
            mode_choice = :lax
        else
            printstyled("Invalid choice. Please enter 1, 2, or 3.\n", color = :red)
        end
    end

    println()
    printstyled("Selected mode: ", color = :cyan)
    printstyled("$mode_choice\n", color = :green, bold = true)
    println()

    # Generate API key (unless in lax mode)
    api_keys = String[]
    if mode_choice != :lax
        println("🔑 Generating API key...")
        sleep(0.3)
        api_key = generate_api_key()
        push!(api_keys, api_key)

        println()
        printstyled("✅ API Key Generated:\n\n", color = :green, bold = true)
        printstyled("    $api_key\n\n", color = :yellow, bold = true)
        printstyled(
            "⚠️  SAVE THIS KEY SECURELY - IT WILL NOT BE SHOWN AGAIN!\n",
            color = :red,
            bold = true,
        )
        println()

        print("Press Enter after you've saved the key...")
        readline()
        println()
    end

    # Configure IP allowlist (for strict mode)
    allowed_ips = ["127.0.0.1", "::1"]  # Always include localhost
    if mode_choice == :strict
        println("🌐 Configure IP Allowlist")
        println()
        println("Current allowed IPs: 127.0.0.1, ::1 (localhost)")
        println()
        print("Add additional IP addresses? [y/N]: ")
        add_ips = strip(lowercase(readline()))

        if add_ips == "y" || add_ips == "yes"
            println()
            println("Enter IP addresses (one per line, empty line to finish):")
            while true
                print("IP: ")
                ip = strip(readline())
                if isempty(ip)
                    break
                end

                # Basic IP validation
                if occursin(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", ip) ||
                   occursin(r"^[0-9a-fA-F:]+$", ip)
                    push!(allowed_ips, ip)
                    printstyled("  ✅ Added: $ip\n", color = :green)
                else
                    printstyled("  ❌ Invalid IP format, skipped\n", color = :red)
                end
            end
        end
        println()
    end

    # Create and save configuration
    println("💾 Saving security configuration...")
    sleep(0.3)

    config = SecurityConfig(mode_choice, api_keys, allowed_ips)

    if save_security_config(config, workspace_dir)
        println()
        printstyled("✅ Security configuration saved!\n\n", color = :green, bold = true)

        # Show final summary
        printstyled("📋 Configuration Summary\n", color = :cyan, bold = true)
        println("─" ^ 50)
        println("Mode:         $mode_choice")
        if mode_choice != :lax
            println("API Keys:     $(length(api_keys)) key(s) generated")
        end
        println("Allowed IPs:  $(length(allowed_ips)) IP(s)")
        println("Config file:  $(get_security_config_path(workspace_dir))")
        println("─" ^ 50)
        println()

        if mode_choice != :lax
            printstyled(
                "⚠️  Remember: The API key grants FULL access to your Julia REPL.\n",
                color = :yellow,
                bold = true,
            )
            printstyled(
                "    Keep it as secure as you would keep your SSH private key!\n",
                color = :yellow,
            )
            println()
        end

        printstyled("🚀 You can now start the server with:\n", color = :green)
        println("     MCPRepl.start!()")
        println()

        return config
    else
        error("Failed to save security configuration")
    end
end

"""
    quick_setup(mode::Symbol=:strict, workspace_dir::String=pwd()) -> SecurityConfig

Quick non-interactive setup for automated environments.
Generates API key and uses default settings.
"""
function quick_setup(mode::Symbol = :strict, workspace_dir::String = pwd())
    if !(mode in [:strict, :relaxed, :lax])
        error("Invalid mode. Must be :strict, :relaxed, or :lax")
    end

    println("⚡ Quick Setup Mode")
    println()

    api_keys = mode == :lax ? String[] : [generate_api_key()]
    allowed_ips = ["127.0.0.1", "::1"]

    config = SecurityConfig(mode, api_keys, allowed_ips)

    if save_security_config(config, workspace_dir)
        println("✅ Security configuration created")
        if mode != :lax
            println()
            println("API Key: $(api_keys[1])")
            println()
            println("⚠️  Save this key securely!")
        end
        println()
        return config
    else
        error("Failed to save security configuration")
    end
end
