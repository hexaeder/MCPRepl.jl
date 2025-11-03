# ============================================================================
# Security Setup Wizard - Dramatic Edition 🐉
# ============================================================================

using Printf

# Load ASCII art from art.jl
include("art.jl")

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
    return occursin("xterm", term) ||
           occursin("mlterm", term) ||
           haskey(ENV, "WEZTERM_EXECUTABLE") ||
           haskey(ENV, "KITTY_PID")
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
         __---~~~.==~||\=_    - --~/_-~|-   |\\   \\        _/~
     _-~~     .=~    |  \\-_   <-/- > /-   /  ||    \      /
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

const WIZARD_COLORS = [33, 39, 45, 51, 87, 123, 159, 105, 69]  # Teal/blue/purple gradient

# ============================================================================
# Butterfly Theme - Gentle & Supportive Edition 🦋
# ============================================================================

const BUTTERFLY_ASCII = raw"""
                    ⋆｡°✩ 
              ✧･ﾟ: *✧･ﾟ:*    *:･ﾟ✧*:･ﾟ✧
           ✧      ⋆｡°✩        ⋆｡°✩      ✧
        ･ﾟ✧   ╱|、         ╱|、   ✧･ﾟ
           (˚ˎ 。7        (˚ˎ 。7
         ✧  |、˜〵         |、˜〵  ✧
            じしˍ,)ノ      じしˍ,)ノ
       ✧                              ✧
          ⋆｡°✩    You've got this!   ⋆｡°✩
               ･ﾟ✧*:･ﾟ✧
                                        
                    _   _
                   (')_(')
                  ( =^·^= )
                  (")_(")_/  ✨
                              
             🦋  Together we'll make    🦋
                this workspace secure!
                                        
                  ⋆｡°✩       ⋆｡°✩
                     ✧･ﾟ: *✧･ﾟ:*
"""

const BUTTERFLY_COLORS = [219, 183, 147, 111, 75, 39, 75, 111, 147, 183]  # Pink/purple gradient
const PASTEL_COLORS = [219, 225, 189, 195, 159, 123, 87]  # Soft pastels
const MOTIVATIONAL_PHRASES = [
    "🌸 You're doing great!",
    "✨ Every step makes you stronger!",
    "🦋 Security is a journey, not a destination",
    "💫 You're learning and growing!",
    "🌺 Progress, not perfection!",
    "⭐ You've got this!",
]
# pad all motivational phrases to same length
max_phrase_length = maximum(length.(MOTIVATIONAL_PHRASES))
for i in eachindex(MOTIVATIONAL_PHRASES)
    MOTIVATIONAL_PHRASES[i] = rpad(MOTIVATIONAL_PHRASES[i], max_phrase_length)
end
"""
    get_wizard_art() -> String

Load wizard ASCII art from art.jl (wiz variable).
"""
function get_wizard_art()
    return wiz
end

"""
    wizard_entrance_animation(; gentle::Bool=false)

Center and render the epic wizard with a subtle shimmering aura.
If gentle=true, adds a butterfly companion next to the wizard.
"""
function wizard_entrance_animation(; gentle::Bool = false)
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

    # Add butterfly companion in gentle mode
    if gentle
        # Use b3 which has nice small butterflies
        butterfly_art = raw"""
   _ " _ 
  (_\|/_)
   (/|\) 
"""
        butterfly_lines = split(butterfly_art, '\n')
        # Position butterfly to the right of wizard
        butterfly_col = start_col + art_width + 5
        butterfly_row = start_row + div(art_height, 3)

        for (i, line) in enumerate(butterfly_lines)
            move_cursor(butterfly_row + i - 1, butterfly_col)
            # Use pastel colors for butterfly
            color = PASTEL_COLORS[mod1(i, length(PASTEL_COLORS))]
            print("\e[38;5;$(color)m" * line * "\e[0m")
        end
    end

    flush(stdout)

    # Twinkles around the wizard for ~2 seconds
    local twinkles = gentle ? ["✧", "✨", "⋆", "🦋"] : ["✧", "✨", "⋆"]
    # Calculate iterations: ~2 seconds with 0.03s sleep = ~66 iterations
    # Using 15 twinkles gives us coverage, so we'll do multiple passes
    for pass = 1:4  # 4 passes * 15 twinkles * 0.03s ≈ 1.8 seconds
        for _ = 1:15
            r = start_row + rand(-2:(art_height+2))
            c = start_col + rand(-2:(art_width+2))
            if r > 0 && r <= rows && c > 0 && c <= cols
                move_cursor(r, c)
                print("\e[38;5;$(rand([51,81,123,159,195]))m" * rand(twinkles) * "\e[0m")
                sleep(0.03)
            end
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
                fire_row = mouth_row + rand((-max(2, spread÷4)):max(2, spread÷4))

                if fire_row > 0 && fire_row <= rows && fire_col > 2
                    move_cursor(fire_row, fire_col)
                    print(
                        "\e[38;5;$(rand(FIRE_COLORS));1m$(rand(["🔥", "💥", "⚡", "✨", "🌟"]))\e[0m",
                    )
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
                    col = rand(1:(cols-2))
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
    gentle_butterfly_animation()

A calming, supportive butterfly animation with motivational messages.
Uses butterflies from art.jl (b1, b2, b3).
"""
function gentle_butterfly_animation()
    hide_cursor()
    rows, cols = get_terminal_size()

    # Soft fade-in
    clear_screen()
    sleep(0.3)

    # Display multiple butterflies from art.jl
    butterfly_arts = [b1, b2, b3]
    all_butterflies = []

    # Position butterflies across the screen
    for (idx, butterfly_art) in enumerate(butterfly_arts)
        lines = split(butterfly_art, '\n')
        art_height = length(lines)
        art_width = maximum(length.(lines))

        # Spread butterflies horizontally
        start_row = max(1, div(rows - art_height, 2) + rand(-5:5))
        start_col = div(cols * idx, length(butterfly_arts) + 1) - div(art_width, 2)

        push!(all_butterflies, (lines, start_row, start_col, art_height, art_width))
    end

    # Gentle fade-in with gradient
    for alpha = 1:length(BUTTERFLY_COLORS)
        clear_screen()
        print("\e[0m")

        # Draw all butterflies
        for (lines, start_row, start_col, art_height, art_width) in all_butterflies
            for (i, line) in enumerate(lines)
                if i <= alpha * div(art_height, length(BUTTERFLY_COLORS))
                    move_cursor(start_row + i - 1, max(1, start_col))
                    color = BUTTERFLY_COLORS[mod1(i, length(BUTTERFLY_COLORS))]
                    print("\e[38;5;$(color)m" * line * "\e[0m")
                end
            end
        end

        flush(stdout)
        sleep(0.15)
    end

    # Calculate average position for message
    avg_row = div(rows, 2)

    # Sparkles and small butterflies floating around
    sparkles = ["✨", "⭐", "✧", "⋆", "˚", "°", "·"]
    small_butterflies = ["🦋", "🌸", "🌺", "🌼", "💮", "🌷"]

    for wave = 1:4
        # Show motivational phrase
        phrase = MOTIVATIONAL_PHRASES[mod1(wave, length(MOTIVATIONAL_PHRASES))]
        phrase_row = min(rows - 2, avg_row + 15)
        phrase_col = max(1, div(cols - length(phrase), 2))
        move_cursor(phrase_row, phrase_col)
        printstyled(phrase, color = :magenta, bold = true)

        # Gentle sparkles and small butterflies
        for _ = 1:20
            r = rand(1:rows)
            c = rand(1:(cols-2))

            # Avoid drawing over the large butterfly art
            skip = false
            for (_, start_row, start_col, art_height, art_width) in all_butterflies
                if r >= start_row - 2 &&
                   r <= start_row + art_height + 2 &&
                   c >= start_col - 5 &&
                   c <= start_col + art_width + 5
                    skip = true
                    break
                end
            end

            if !skip
                move_cursor(r, c)
                if rand() > 0.5
                    print("\e[38;5;$(rand(PASTEL_COLORS))m" * rand(sparkles) * "\e[0m")
                else
                    print(rand(small_butterflies))
                end
            end

            flush(stdout)
            sleep(0.04)
        end

        sleep(0.5)
    end

    # Final calm state
    sleep(0.5)
    clear_screen()
    print("\e[0m")
    show_cursor()
end

"""
    supportive_message_box(title::String, messages::Vector{String})

Display a gentle, supportive message box.
"""
function supportive_message_box(title::String, messages::Vector{String})
    println()
    printstyled(
        "╔═══════════════════════════════════════════════════════════════════╗\n",
        color = :light_magenta,
    )
    printstyled("║  ", color = :light_magenta)
    printstyled("$title", color = :cyan, bold = true)
    padding = 65 - length(title)
    print(" " ^ (padding-2))
    printstyled("║\n", color = :light_magenta)
    printstyled(
        "╚═══════════════════════════════════════════════════════════════════╝\n",
        color = :light_magenta,
    )
    println()

    for msg in messages
        printstyled("  💫 ", color = :light_yellow)
        println(msg)
    end
    println()
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
    security_setup_wizard(workspace_dir::String=pwd(); force::Bool=false, gentle::Bool=false) -> SecurityConfig

Launch the security setup wizard with either dramatic dragon theme or gentle butterfly theme.
Set `gentle=true` for a supportive, calm experience without scary dragons.
"""
function security_setup_wizard(
    workspace_dir::String = pwd();
    force::Bool = false,
    gentle::Bool = false,
)
    # Check if config already exists
    existing_config = load_security_config(workspace_dir)
    if existing_config !== nothing && !force
        println()
        printstyled(
            "✅ Security configuration already exists\n",
            color = :green,
            bold = true,
        )
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

    if gentle
        # GENTLE BUTTERFLY ENTRANCE
        clear_screen()
        sleep(0.3)

        # Show butterflies and motivation
        gentle_butterfly_animation()

        sleep(0.5)

        # Supportive security information
        supportive_message_box(
            "🌸 Let's Set Up Your Workspace Security! 🌸",
            [
                "We're going to configure some security settings together.",
                "This will help keep your workspace safe and sound.",
                "Don't worry - I'll guide you through each step!",
                "",
                "Security is important because this tool can run code.",
                "We'll set up protection so only you can use it.",
                "Think of it like putting a lock on your door. 🔐",
            ],
        )
    else
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
            ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, 1)

            while typed_text != target_text
                if eof(stdin)
                    break
                end

                char = read(stdin, Char)

                if char == ' '
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
                elseif char == '\r' || char == '\n'
                    break
                elseif char == '\x7f' || char == '\b'
                    if !isempty(typed_text)
                        typed_text = typed_text[1:(end-1)]
                        space_count = max(0, space_count - 1)
                        print("\b \b")
                        flush(stdout)
                    end
                else
                    # Accept any printable character for manual typing
                    typed_text *= char
                    print(char)
                    flush(stdout)
                end
            end
        finally
            ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, 0)
        end

        println()

        if typed_text != target_text
            error("Security setup cancelled by user")
        end

        println()
        printstyled("✅ Acknowledgment accepted. Proceeding with setup...\n", color = :green)
        println()
        sleep(0.8)

        # The Wizard appears!
        wizard_entrance_animation(gentle = gentle)
        println()
        sleep(0.6)

        printstyled("The wizard speaks: ", color = :magenta, bold = true)
        sleep(0.5)
        animate_text("\"Let us configure your realm's defenses...\"", 0.04)
        println()
        sleep(0.8)
    end  # End of if gentle / else dragon theme

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

    # Configure port
    println("🌐 Configure Server Port")
    println()
    println("The MCP server will listen on this port (default: 3000).")
    println("You can also override this with the JULIA_MCP_PORT environment variable.")
    println()
    print("Port number [3000]: ")
    port_input = strip(readline())

    port = 3000  # default
    if !isempty(port_input)
        try
            port = parse(Int, port_input)
            if port < 1024 || port > 65535
                printstyled(
                    "⚠️  Port must be between 1024 and 65535, using default 3000\n",
                    color = :yellow,
                )
                port = 3000
            end
        catch
            printstyled("⚠️  Invalid port number, using default 3000\n", color = :yellow)
            port = 3000
        end
    end

    printstyled("✓ Using port: $port\n", color = :green)
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
        printstyled("        \"url\": \"http://localhost:$port\",\n", color = :white)
        printstyled("        \"headers\": {\n", color = :white)
        printstyled("          \"Authorization\": \"Bearer $api_key\"\n", color = :yellow)
        printstyled("        }\n", color = :white)
        printstyled("      }\n", color = :white)
        printstyled("    }\n", color = :white)
        printstyled("  }\n\n", color = :white)

        println("  Or set the environment variable:")
        printstyled("    export JULIA_MCP_API_KEY=\"$api_key\"\n\n", color = :yellow)

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
    config = SecurityConfig(mode_choice, api_keys, allowed_ips, port)

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
        printstyled("  \"port\": $port,\n", color = :cyan)
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
        printstyled(
            "⚠️  Server cannot start without security configuration!\n",
            color = :red,
            bold = true,
        )
        println("Create the file manually, then run MCPRepl.start!()")
        println()
        return config
    end
end

"""
    quick_setup(mode::Symbol=:strict, port::Int=3000, workspace_dir::String=pwd()) -> SecurityConfig

Quick non-interactive setup for automated environments.
Generates API key and uses default settings.
"""
function quick_setup(
    mode::Symbol = :strict,
    port::Int = 3000,
    workspace_dir::String = pwd(),
)
    if !(mode in [:strict, :relaxed, :lax])
        error("Invalid mode. Must be :strict, :relaxed, or :lax")
    end

    println("⚡ Quick Setup Mode")
    println()

    api_keys = mode == :lax ? String[] : [generate_api_key()]
    allowed_ips = ["127.0.0.1", "::1"]

    config = SecurityConfig(mode, api_keys, allowed_ips, port)

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

"""
    gentle_setup(mode::Symbol=:strict, port::Int=3000, workspace_dir::String=pwd()) -> SecurityConfig

Gentle version of security setup with butterflies instead of dragons! 🦋
Perfect for users who prefer a supportive, calm experience.

Uses the same security configuration options as the regular setup,
but with a kinder, more encouraging presentation.
"""
function gentle_setup(
    _mode::Symbol = :strict,
    _port::Int = 3000,
    workspace_dir::String = pwd(),
)
    return security_setup_wizard(workspace_dir; force = false, gentle = true)
end
