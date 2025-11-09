using Test
using MCPRepl

@testset "Generate Module" begin
    @testset "VSCODE_ALLOWED_COMMANDS" begin
        commands = MCPRepl.Generate.VSCODE_ALLOWED_COMMANDS

        @testset "No duplicates" begin
            unique_commands = unique(commands)
            @test length(commands) == length(unique_commands)

            if length(commands) != length(unique_commands)
                # Find and report duplicates for debugging
                seen = Set{String}()
                duplicates = String[]
                for cmd in commands
                    if cmd in seen
                        push!(duplicates, cmd)
                    else
                        push!(seen, cmd)
                    end
                end
                @warn "Found duplicate commands" duplicates
            end
        end

        @testset "All commands are strings" begin
            @test all(cmd -> isa(cmd, String), commands)
        end

        @testset "No empty strings" begin
            @test all(cmd -> !isempty(cmd), commands)
        end

        @testset "Commands follow VS Code naming convention" begin
            # All commands should contain at least one dot
            @test all(cmd -> contains(cmd, "."), commands)
        end

        @testset "List is not empty" begin
            @test !isempty(commands)
            @test length(commands) > 0
        end

        @testset "Commands are sorted (for maintainability)" begin
            # This is a recommendation, not a strict requirement
            # Sorting makes it easier to spot duplicates and maintain the list
            sorted_commands = sort(commands)
            if commands != sorted_commands
                @info "Commands list is not sorted. Consider sorting for easier maintenance."
            end
        end
    end

    @testset "Function exports" begin
        # Verify that expected functions are exported
        exported_names = names(MCPRepl.Generate)

        @test :generate in exported_names
        @test :create_security_config in exported_names
        @test :create_startup_script in exported_names
        @test :create_vscode_config in exported_names
        @test :create_vscode_settings in exported_names
        @test :create_claude_config_template in exported_names
        @test :create_gemini_config_template in exported_names
        @test :create_gitignore in exported_names
    end

    @testset "Project Generation" begin
        # Create a temporary directory for the test project
        mktempdir() do tmpdir
            project_name = "TestProject"
            # The generate function appends .jl to the project name for the directory
            project_path = joinpath(tmpdir, project_name * ".jl")

            # Run the generate function
            MCPRepl.Generate.generate(project_name, path=tmpdir, security_mode=:lax)

            # Check if the main project directory was created
            @test isdir(project_path)

            # Check for key directories
            @test isdir(joinpath(project_path, "src"))
            @test isdir(joinpath(project_path, "test"))
            @test isdir(joinpath(project_path, ".mcprepl"))
            @test isdir(joinpath(project_path, ".vscode"))

            # Check for key files
            @test isfile(joinpath(project_path, "Project.toml"))
            @test isfile(joinpath(project_path, ".julia-startup.jl"))
            @test isfile(joinpath(project_path, "repl"))
            @test isfile(joinpath(project_path, "README.md"))
            @test isfile(joinpath(project_path, "AGENTS.md"))
            @test isfile(joinpath(project_path, ".gitignore"))
            @test isfile(joinpath(project_path, ".mcprepl", "security.json"))
            @test isfile(joinpath(project_path, ".vscode", "mcp.json"))
            @test isfile(joinpath(project_path, ".vscode", "settings.json"))
        end
    end
end
