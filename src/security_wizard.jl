# ============================================================================
# Security Setup Wizard - Dramatic Edition 🐉
# ============================================================================

using Printf

# Terminal control codes
const CLEAR_SCREEN = "\e[2J"
const MOVE_CURSOR_HOME = "\e[H"
const HIDE_CURSOR = "\e[?25l"
const SHOW_CURSOR = "\e[?25h"
const SAVE_CURSOR = "\e[s"
const RESTORE_CURSOR = "\e[u"
const BOLD = "\e[1m"
const BLINK = "\e[5m"
const REVERSE = "\e[7m"
const RESET = "\e[0m"

# Color codes for 256-color terminals
const RED_GRADIENT = [196, 160, 124, 88, 52]
const FIRE_COLORS = [196, 202, 208, 214, 220, 226, 220, 214, 208, 202]
const ORANGE_FIRE = [202, 208, 214, 220, 226]
const YELLOW_FIRE = [220, 226, 227, 228, 229, 230]

"""
    move_cursor(row::Int, col::Int)

Move cursor to specific position.
"""
function move_cursor(row::Int, col::Int)
    print("\e[$(row);$(col)H")
    flush(stdout)
end

"""
    get_terminal_size()

Get terminal dimensions (rows, cols).
"""
function get_terminal_size()
    try
        return (parse(Int, readchomp(`tput lines`)), parse(Int, readchomp(`tput cols`)))
    catch
        return (24, 80)  # Default fallback
    end
end

"""
    clear_screen()

Clear the terminal screen and move cursor to home.
"""
function clear_screen()
    print(CLEAR_SCREEN)
    print(MOVE_CURSOR_HOME)
    flush(stdout)
end

"""
    hide_cursor()

Hide the terminal cursor.
"""
function hide_cursor()
    print(HIDE_CURSOR)
    flush(stdout)
end

"""
    show_cursor()

Show the terminal cursor.
"""
function show_cursor()
    print(SHOW_CURSOR)
    flush(stdout)
end

"""
    check_sixel_support()

Check if terminal supports Sixel graphics.
"""
function check_sixel_support()
    # Check if we're in a terminal that might support Sixel
    term = get(ENV, "TERM", "")
    return occursin("xterm", term) || occursin("mlterm", term) || 
           haskey(ENV, "WEZTERM_EXECUTABLE") || haskey(ENV, "KITTY_PID")
end

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

const DRAGON_MOUTH_OPEN = raw"""
                                                     __----~~~~~~~~~~~------___
                                    .  .   ~~//====......          __--~ ~~
                    -.            \_|//     |||\\  ~~~~~~::::... /~
                 ___-==_       _-~O~  \/    |||  \\            _/~~-
         __---~~~.==~||\=_    -_--~/_-~|-   |\\   \\        _/~
     _-~~     .=~    |  \\-_    '-O>>  /-   /  ||    \      /
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

const WIZARD_ASCII = raw"""
                                                     .        *       .   *
                                             *        .       *         .
                                         .        .-^^^-.       .
                                         /\      /  * *  \     /\
                                        /__\    /_________\   /__\
                                    _/____\    \  ___  /   /____\_
                                 /  .--. \    |/ _ \|    / .--.  \
                                /  /    \ \   | (_) |   / /    \  \
                             /  / /\   \ \  |\___/|  / /   /\ \  \
                            /__/ /  \___\_\ |\   /| /_/___/  \_\__\
                             \  /  .-""-.  / | '-' | \  .-""-.  \  /
                                \/  /  ()  \ \ |  |  | / /  ()  \  \/
                                 | |   /\   | | |  |  | |   /\   | |
                                 | |  (  )  | | |  |  | |  (  )  | |
                                 | |   \/   | | |  |  | |   \/   | |
                             __| |_________| |_|__|_| |_________| |__
                        .-'   /  .-..-.   \  .--.  /   .-..-.  \   '-.
                    .'     /  /  /  \   \ |__| /   /  /  \  \      '.
                 /      /__/__/____\   \____/   /____\__\__\       \
                /       \  .--------.   .--.   .--------.  /        \
             /         \ '--------'  (____)  '--------' /          \
            ;           \    ···      (____)     ···   /            ;
            |            \ .  o  .   .(____).   .  o . /            |
            |             '--------- .  \__/  . --------'            |
            |                .  .   (    --    )   .  .              |
            |                 ·  ·   '-.____.-'    ·  ·              |
            |                     .     |  |     .                   |
            |                    /|\    |  |    /|\                  |
            |                   / | \   |  |   / | \                 |
            |                  /  |  \  |  |  /  |  \                |
            |                 /___|___\_|__|_/___|___\               |
             \                 .  .  .  |  |  .  .  .               /
                \                   b      |       b                  /
                 \                  Bb     |      Bb                 /
                    \                dBBBb   |    dBBBb               /
                     '------------------------------------------------'

                      ✨ THE SECURITY WIZARD MATERIALIZES ✨
"""

const WIZARD_COLORS = [33, 39, 45, 51, 87, 123, 159, 105, 69]  # Teal/blue/purple gradient

"""
    get_wizard_art() -> String

Prefer external ASCII art from `src/wiz` if present; fall back to built-in
WIZARD_ASCII. This lets users drop in custom art without recompiling.
"""
function get_wizard_art()
    # Try repo-local path (works when running from project root) and module path
    candidates = String[
        joinpath(pwd(), "src", "wiz"),
        joinpath(@__DIR__, "wiz"),
    ]
    for path in candidates
        if isfile(path)
            try
                return read(path, String)
            catch
                # ignore and try next candidate
            end
        end
    end
    return WIZARD_ASCII
end

"""
    wizard_entrance_animation()

Center and render the epic wizard with a subtle shimmering aura.
"""
function wizard_entrance_animation()
    rows, cols = get_terminal_size()
    clear_screen()
    sleep(0.15)

    lines = split(get_wizard_art(), '\n')
    art_height = length(lines)
    art_width = maximum(length.(lines))
    start_row = max(1, div(rows - art_height, 2))
    start_col = max(1, div(cols - art_width, 2))

    # Draw wizard with vertical gradient
    for (i, line) in enumerate(lines)
        move_cursor(start_row + i - 1, start_col)
        color = WIZARD_COLORS[mod1(i, length(WIZARD_COLORS))]
        print("\e[38;5;$(color)m" * line * "\e[0m")
    end

    flush(stdout)

    # A few subtle twinkles around the wizard
    local twinkles = ["✧", "✨", "⋆"]
    # Increase density by ~50%
    for _ in 1:15
        r = start_row + rand(-2:art_height+2)
        c = start_col + rand(-2:art_width+2)
        if r > 0 && r <= rows && c > 0 && c <= cols
            move_cursor(r, c)
            print("\e[38;5;$(rand([51,81,123,159,195]))m" * rand(twinkles) * "\e[0m")
            sleep(0.03)
        end
    end

    # Set cursor just below art
    move_cursor(min(rows, start_row + art_height + 1), 1)
    print("\e[0m")
    flush(stdout)
end

"""
    print_with_color_gradient(text::String, colors::Vector{Int})

Print text with a 256-color gradient, ensuring proper reset.
"""
function print_with_color_gradient(text::String, colors::Vector{Int})
    lines = split(text, '\n')
    for (i, line) in enumerate(lines)
        color_idx = mod1(i, length(colors))
        print("\e[38;5;$(colors[color_idx])m")
        println(line)
    end
    print("\e[0m")  # Always reset after
    flush(stdout)
end

"""
    detect_mouth_origin() -> (row::Int, col::Int)

Try to locate the dragon mouth by scanning the closed-mouth ASCII for the
"'-~7" mouth cluster. Fallback to a sensible default if not found.
"""
function detect_mouth_origin()
    lines = split(DRAGON_ASCII, '\n')
    for (i, line) in enumerate(lines)
        idx = findfirst("'-~7", line)
        if idx !== nothing
            # Place the emission point near the middle of the mouth cluster
            return (i, first(idx) + 2)
        end
    end
    # Fallback (close to the head area)
    return (7, 27)
end

"""
    breathing_dragon_animation()

Animate the dragon breathing EPIC fire OUT OF HIS MOUTH!
"""
function breathing_dragon_animation()
    hide_cursor()
    rows, cols = get_terminal_size()
    
    # Completely clear and reset terminal
    clear_screen()
    print("\e[0m")  # Reset all attributes
    sleep(0.5)
    
    # Slow fade-in of dragon from darkness
    for alpha = 1:length(RED_GRADIENT)
        clear_screen()
        print("\e[0m")  # Reset
        print_with_color_gradient(DRAGON_ASCII, RED_GRADIENT[1:alpha])
        sleep(0.2)
    end
    
    sleep(0.4)
    
    # Determine mouth origin dynamically from ASCII
    # Fire streams LEFT from the mouth origin
    mouth_row, mouth_col_start = detect_mouth_origin()
    
    # MASSIVE FIRE BREATHING SEQUENCE
    for breath = 1:4
        # Build up (inhale) - dragon glows, mouth CLOSED
        for frame = 1:3
            print("\e[H")
            # Darker, building tension
            print_with_color_gradient(DRAGON_ASCII, reverse(RED_GRADIENT))
            
            if frame == 3
                # Sparks gathering at mouth
                for _ = 1:8
                    offset = rand(-2:2)
                    move_cursor(mouth_row + offset, mouth_col_start + rand(-5:5))
                    print("\e[38;5;$(rand(ORANGE_FIRE))m✨\e[0m")
                end
            end
            sleep(0.15)
        end
        
        # EXPLOSIVE FIRE BREATH - mouth OPENS and fire streams!
        for explosion = 1:6
            print("\e[H")
            # Dragon with MOUTH OPEN glows bright
            if explosion % 2 == 0
                print_with_color_gradient(DRAGON_MOUTH_OPEN, FIRE_COLORS)
            else
                print_with_color_gradient(DRAGON_MOUTH_OPEN, YELLOW_FIRE)
            end
            
            # FIRE STREAMS LEFT (toward viewer) from dragon's mouth
            for distance = 1:38
                # Fire flows LEFT horizontally from mouth
                fire_col = mouth_col_start - distance * 2
                if fire_col > 2
                    # Main fire stream
                    # Slight upward curl close to mouth
                    curl = distance < 8 ? rand(-1:0) : rand(-2:2)
                    fire_row = clamp(mouth_row + curl, 1, rows)
                    move_cursor(fire_row, fire_col)
                    
                    # Closer to mouth = hotter (yellow), further = cooler (red)
                    if distance < 10
                        fire_char = rand(["�", "�", "⚡"])
                        color = rand(YELLOW_FIRE)
                    elseif distance < 20
                        fire_char = rand(["🔥", "💥", "✨"])
                        color = rand(ORANGE_FIRE)
                    else
                        fire_char = rand(["🔥", "✨"])
                        color = rand(FIRE_COLORS[1:6])
                    end
                    
                    print("\e[38;5;$(color);1m$(fire_char)\e[0m")
                    
                    # Smoke particles above and below
                    if rand() > 0.5
                        smoke_row = fire_row + rand([-3, -2, -1, 1, 2, 3])
                        smoke_col = fire_col + rand(-3:3)
                        if smoke_row > 0 && smoke_row <= rows && smoke_col > 1
                            move_cursor(smoke_row, smoke_col)
                            print("\e[38;5;$(rand([240, 241, 242, 243, 244]))m░\e[0m")
                        end
                    end
                end
            end
            
            # Additional fire particles spreading in cone LEFT from mouth
            for _ = 1:18
                spread = rand(5:44)
                fire_col = mouth_col_start - spread
                fire_row = mouth_row + rand(-max(2, spread÷4):max(2, spread÷4))
                
                if fire_row > 0 && fire_row <= rows && fire_col > 2
                    move_cursor(fire_row, fire_col)
                    print("\e[38;5;$(rand(FIRE_COLORS));1m$(rand(["🔥", "💥", "⚡", "✨", "🌟"]))\e[0m")
                end
            end
            
            flush(stdout)
            sleep(0.08)
        end
        
        # Cool down - smoke dissipates, mouth CLOSES
        for frame = 1:2
            print("\e[H")
            print_with_color_gradient(DRAGON_ASCII, ORANGE_FIRE)
            
            # Lingering smoke
            for _ = 1:10
                smoke_col = mouth_col_start - rand(10:60)
                smoke_row = mouth_row + rand(-8:8)
                if smoke_row > 0 && smoke_row <= rows && smoke_col > 1
                    move_cursor(smoke_row, smoke_col)
                    print("\e[38;5;$(rand([237, 238, 239, 240]))m░\e[0m")
                end
            end
            
            flush(stdout)
            sleep(0.15)
        end
    end
    
    # Final MEGA BREATH - MOUTH WIDE OPEN, longest fire stream LEFT!
    for frame = 1:12
        print("\e[H")
        # Alternate between super bright colors with mouth open
        if frame % 2 == 0
            print_with_color_gradient(DRAGON_MOUTH_OPEN, YELLOW_FIRE)
        else
            print_with_color_gradient(DRAGON_MOUTH_OPEN, FIRE_COLORS)
        end
        
        # MASSIVE fire jet streaming LEFT
        for distance = 1:56
            fire_col = mouth_col_start - distance * 2
            if fire_col > 2
                for width = -3:4
                    curl = distance < 12 ? -1 : 0
                    fire_row = clamp(mouth_row + width + curl + rand(-1:1), 1, rows)
                    if fire_row > 0 && fire_row <= rows
                        move_cursor(fire_row, fire_col)
                        
                        if distance < 16
                            print("\e[38;5;$(rand(YELLOW_FIRE));1m💥\e[0m")
                        elseif distance < 34
                            print("\e[38;5;$(rand(ORANGE_FIRE));1m🔥\e[0m")
                        else
                            print("\e[38;5;$(rand(FIRE_COLORS));1m✨\e[0m")
                        end
                    end
                end
            end
        end
        
        flush(stdout)
        sleep(0.1)
    end
    
    # Fade to red with smoke clearing
    sleep(0.3)
    clear_screen()
    print("\e[0m")  # Reset all attributes
    print_with_color_gradient(DRAGON_ASCII, RED_GRADIENT)
    
    # Move cursor below dragon
    println("\n")
    print("\e[0m")  # Final reset
    show_cursor()
end

"""
    flash_warning(times::Int=3)

INTENSE warning flashes that will get anyone's attention!
"""
function flash_warning(times::Int = 3)
    hide_cursor()
    rows, cols = get_terminal_size()
    
    for round = 1:times
        # Build intensity
        for speed_mult = 1:3
            for (idx, flame) in enumerate(FLAMES)
                # Full screen flash
                clear_screen()
                
                # Random flames across entire screen
                num_flames = 50 + round * 20
                for _ = 1:num_flames
                    row = rand(1:rows)
                    col = rand(1:cols-2)
                    move_cursor(row, col)
                    
                    color = FIRE_COLORS[mod1(round * idx, length(FIRE_COLORS))]
                    print("\e[38;5;$(color);1m$(flame)\e[0m")
                end
                
                # Center warning
                center_row = div(rows, 2)
                center_col = div(cols, 2) - 20
                move_cursor(center_row, center_col)
                print("$(BOLD)$(BLINK)\e[38;5;196m")
                print(" ⚠️  DANGER ZONE  ⚠️ ")
                print("$(RESET)")
                
                flush(stdout)
                sleep(0.05 / speed_mult)
            end
        end
    end
    
    # Final clear - ensure everything is gone and attributes reset
    clear_screen()
    move_cursor(1, 1)
    print("\e[0m")  # Reset all attributes
    show_cursor()
end

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
    security_setup_wizard(workspace_dir::String=pwd(); force::Bool=false) -> SecurityConfig

Launch the EPIC security setup wizard with animated dragon!
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

    # EPIC DRAGON ENTRANCE
    clear_screen()
    sleep(0.3)
    
    # Animate the dragon breathing fire
    breathing_dragon_animation()
    
    sleep(0.5)

    # Flash warnings with increasing intensity
    flash_warning(3)

    # Clean transition - aggressively clear everything
    sleep(0.3)
    
    # Multiple clears to ensure everything is gone
    for _ = 1:3
        clear_screen()
        print("\e[0m")  # Reset all terminal attributes
        sleep(0.05)
    end
    
    move_cursor(1, 1)
    sleep(0.2)
    
    # Add top padding and start drawing box from clean position
    println("\n")
    print("\e[0m")  # Extra reset before drawing box
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
        "║    YOU ARE CONFIGURING A REMOTE CODE EXECUTION SERVER             ║\n",
        color = :red,
        bold = true,
    )
    printstyled(
        "║                                                                   ║\n",
        color = :yellow,
        bold = true,
    )
    printstyled(
        "║  This server will execute ANY code sent to it by authenticated    ║\n",
        color = :white,
    )
    printstyled(
        "║  clients. While MCPRepl includes security features, it is still   ║\n",
        color = :white,
    )
    printstyled(
        "║  fundamentally a powerful and potentially dangerous tool.         ║\n",
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
        "║    • Keep API keys secret and secure                              ║\n",
        color = :white,
    )
    printstyled(
        "║    • Never commit .mcprepl/ directory to version control          ║\n",
        color = :white,
    )
    printstyled(
        "║    • Only allow trusted IPs in production environments            ║\n",
        color = :white,
    )
    printstyled(
        "║    • Understand that API keys grant FULL code execution rights    ║\n",
        color = :white,
    )
    printstyled(
        "║    • Take responsibility for any code executed through this       ║\n",
        color = :white,
    )
    printstyled(
        "║      server and understand the security implications              ║\n",
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

    # Force explicit acknowledgment with character-by-character input
    printstyled(
        "Hold SPACE to continue (or type 'I UNDERSTAND THE RISKS'): ",
        color = :red,
        bold = true,
    )
    
    target_text = "I UNDERSTAND THE RISKS"
    typed_text = ""
    space_count = 0
    
    # Enable raw mode to read characters one by one
    try
        Base.Libc.systemsleep(0.01)
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, 1)
        
        while true
            if eof(stdin)
                break
            end
            
            c = read(stdin, Char)
            
            if c == ' '
                space_count += 1
                # Auto-type the message as they hold space
                if space_count <= length(target_text)
                    print(target_text[space_count])
                    typed_text *= string(target_text[space_count])
                    flush(stdout)
                end
                
                if space_count >= length(target_text)
                    break
                end
            elseif c == '\r' || c == '\n'
                break
            elseif c == '\x7f' || c == '\b'  # Backspace
                if !isempty(typed_text)
                    typed_text = typed_text[1:end-1]
                    space_count = max(0, space_count - 1)
                    print("\b \b")
                    flush(stdout)
                end
            else
                print(c)
                typed_text *= string(c)
                flush(stdout)
            end
        end
    finally
        # Restore normal mode
        ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, 0)
    end
    
    println()

    if typed_text != target_text
        println()
        printstyled("❌ Setup cancelled. Safety first! 🛡️\n", color = :green, bold = true)
        println()
        error("Security setup cancelled by user")
    end

    println()
    printstyled("✅ Acknowledgment accepted. Proceeding with setup...\n", color = :green)
    println()
    sleep(0.8)
    
    # The Wizard appears!
    wizard_entrance_animation()
    println()
    sleep(0.6)
    
    printstyled("The wizard speaks: ", color = :magenta, bold = true)
    sleep(0.5)
    animate_text("\"Let us configure your realm's defenses...\"", 0.04)
    println()
    sleep(0.8)

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
        
        # Add configuration instructions
        printstyled("📝 How to configure your MCP client:\n\n", color = :cyan, bold = true)
        println("  Add this to your MCP client configuration:")
        println()
        printstyled("  {\n", color = :white)
        printstyled("    \"mcpServers\": {\n", color = :white)
        printstyled("      \"julia-repl\": {\n", color = :white)
        printstyled("        \"url\": \"http://localhost:3000\",\n", color = :white)
        printstyled("        \"headers\": {\n", color = :white)
        printstyled("          \"Authorization\": \"Bearer $api_key\"\n", color = :yellow)
        printstyled("        }\n", color = :white)
        printstyled("      }\n", color = :white)
        printstyled("    }\n", color = :white)
        printstyled("  }\n\n", color = :white)
        
        println("  Or set the environment variable:")
        printstyled("    export MCPREPL_API_KEY=\"$api_key\"\n\n", color = :yellow)

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

    # Ask about automatic configuration file creation
    println()
    printstyled("📁 Configuration File Location\n", color = :cyan, bold = true)
    println()
    println("The security configuration will be saved to:")
    config_path = get_security_config_path(workspace_dir)
    printstyled("  $config_path\n", color = :yellow)
    println()
    print("Create this file automatically? [Y/n]: ")
    auto_create = strip(lowercase(readline()))
    
    should_save = isempty(auto_create) || auto_create == "y" || auto_create == "yes"

    # Create and save configuration
    config = SecurityConfig(mode_choice, api_keys, allowed_ips)

    if should_save
        println()
        println("💾 Saving security configuration...")
        sleep(0.3)

        if save_security_config(config, workspace_dir)
            println()
            printstyled("✅ Security configuration saved!\n\n", color = :green, bold = true)
        else
            error("Failed to save security configuration")
        end
    else
        println()
        printstyled("📋 Manual Configuration Required\n", color = :yellow, bold = true)
        println()
        println("Please create the file manually at:")
        printstyled("  $config_path\n\n", color = :yellow)
        println("With the following content:")
        println()
        
        # Show the configuration they need to create manually
        printstyled("{\n", color = :cyan)
        printstyled("  \"mode\": \"$mode_choice\",\n", color = :cyan)
        printstyled("  \"api_keys\": [", color = :cyan)
        if !isempty(api_keys)
            printstyled("\"$(api_keys[1])\"", color = :cyan)
        end
        printstyled("],\n", color = :cyan)
        printstyled("  \"allowed_ips\": [", color = :cyan)
        for (i, ip) in enumerate(allowed_ips)
            printstyled("\"$ip\"", color = :cyan)
            if i < length(allowed_ips)
                printstyled(", ", color = :cyan)
            end
        end
        printstyled("],\n", color = :cyan)
        printstyled("  \"created_at\": $(Int64(round(time())))\n", color = :cyan)
        printstyled("}\n", color = :cyan)
        println("\n")
    end

    if should_save
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
        printstyled("⚠️  Server cannot start without security configuration!\n", color = :red, bold = true)
        println("Create the file manually, then run MCPRepl.start!()")
        println()
        return config
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
