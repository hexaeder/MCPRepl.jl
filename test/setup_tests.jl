using Test
using MCPRepl
using JSON

@testset "Setup Tests" begin
    # Create a temporary directory for testing
    temp_dir = mktempdir()

    try
        @testset "VS Code Configuration" begin
            # Change to temp directory
            original_dir = pwd()
            cd(temp_dir)

            try
                # Test 1: Check status when no config exists
                @test MCPRepl.check_vscode_status() == :not_configured

                # Test 2: Get path for non-existent config
                mcp_path = MCPRepl.get_vscode_workspace_mcp_path()
                @test endswith(mcp_path, ".vscode/mcp.json")
                @test !isfile(mcp_path)

                # Test 3: Add HTTP transport
                @test MCPRepl.add_vscode_mcp_server("http", 3000) == true
                @test isfile(mcp_path)

                # Test 4: Verify config was created correctly
                config = MCPRepl.read_vscode_mcp_config()
                @test config !== nothing
                @test haskey(config, "servers")
                @test haskey(config["servers"], "julia-repl")
                @test config["servers"]["julia-repl"]["type"] == "http"
                @test config["servers"]["julia-repl"]["url"] == "http://localhost:3000"

                # Test 5: Check status after configuration
                @test MCPRepl.check_vscode_status() == :configured_http

                # Test 6: Update to different port
                @test MCPRepl.add_vscode_mcp_server("http", 4000) == true
                config = MCPRepl.read_vscode_mcp_config()
                @test config["servers"]["julia-repl"]["url"] == "http://localhost:4000"

                # Test 7: Change to stdio transport
                @test MCPRepl.add_vscode_mcp_server("stdio", 3000) == true
                config = MCPRepl.read_vscode_mcp_config()
                @test config["servers"]["julia-repl"]["type"] == "stdio"
                @test config["servers"]["julia-repl"]["command"] ==
                      joinpath(pkgdir(MCPRepl), "mcp-julia-adapter")
                @test config["servers"]["julia-repl"]["args"] == ["3000"]

                # Test 8: Check status after stdio config
                @test MCPRepl.check_vscode_status() == :configured_stdio

                # Test 9: Remove configuration
                @test MCPRepl.remove_vscode_mcp_server() == true
                config = MCPRepl.read_vscode_mcp_config()
                @test !haskey(config["servers"], "julia-repl")
                @test MCPRepl.check_vscode_status() == :not_configured

                # Test 10: Remove when already removed (idempotent)
                @test MCPRepl.remove_vscode_mcp_server() == true

            finally
                cd(original_dir)
            end
        end

        @testset "Config File Handling" begin
            cd(temp_dir)
            original_dir = pwd()

            try
                # Create a fresh temp directory for this test
                test_subdir = joinpath(temp_dir, "config_test")
                mkdir(test_subdir)
                cd(test_subdir)

                # Test 1: Read non-existent config
                @test MCPRepl.read_vscode_mcp_config() === nothing

                # Test 2: Write then read config
                MCPRepl.add_vscode_mcp_server("http", 5000)
                config = MCPRepl.read_vscode_mcp_config()
                @test config !== nothing
                @test haskey(config, "servers")

                # Test 3: Verify .vscode directory was created
                @test isdir(joinpath(test_subdir, ".vscode"))

            finally
                cd(original_dir)
            end
        end

        @testset "Port Configuration" begin
            cd(temp_dir)
            original_dir = pwd()

            try
                # Clean any existing config
                vscode_dir = joinpath(temp_dir, ".vscode")
                if isdir(vscode_dir)
                    rm(vscode_dir, recursive = true)
                end

                # Test different port numbers
                test_ports = [3000, 3003, 8080, 9000]

                for port in test_ports
                    MCPRepl.add_vscode_mcp_server("http", port)
                    config = MCPRepl.read_vscode_mcp_config()
                    @test config["servers"]["julia-repl"]["url"] == "http://localhost:$port"
                end

                # Test stdio with different ports
                for port in test_ports
                    MCPRepl.add_vscode_mcp_server("stdio", port)
                    config = MCPRepl.read_vscode_mcp_config()
                    @test config["servers"]["julia-repl"]["args"] == [string(port)]
                end

            finally
                cd(original_dir)
            end
        end

        @testset "VS Code Settings.json Management" begin
            original_dir = pwd()
            cd(temp_dir)

            try
                settings_path = MCPRepl.get_vscode_settings_path()

                # Test 1: Read non-existent settings
                settings = MCPRepl.read_vscode_settings()
                @test settings isa Dict
                @test isempty(settings)

                # Test 2: Write settings
                test_settings = Dict("test.key" => "value")
                @test MCPRepl.write_vscode_settings(test_settings) == true
                @test isfile(settings_path)

                # Test 3: Read back settings
                settings = MCPRepl.read_vscode_settings()
                @test haskey(settings, "test.key")
                @test settings["test.key"] == "value"

                # Test 4: Configure julia.additionalArgs (empty settings)
                rm(joinpath(temp_dir, ".vscode"), recursive = true)
                @test MCPRepl.configure_vscode_julia_args() == true
                settings = MCPRepl.read_vscode_settings()
                @test haskey(settings, "julia.additionalArgs")
                @test length(settings["julia.additionalArgs"]) == 1
                @test contains(settings["julia.additionalArgs"][1], "--load")
                @test contains(settings["julia.additionalArgs"][1], ".julia-startup.jl")

                # Test 5: Check startup configured
                @test MCPRepl.check_vscode_startup_configured() == true

                # Test 6: Configure julia.additionalArgs (existing args)
                existing_settings =
                    Dict("julia.additionalArgs" => ["--project", "--threads=4"])
                MCPRepl.write_vscode_settings(existing_settings)
                @test MCPRepl.configure_vscode_julia_args() == true
                settings = MCPRepl.read_vscode_settings()
                @test length(settings["julia.additionalArgs"]) == 3
                @test "--project" in settings["julia.additionalArgs"]
                @test "--threads=4" in settings["julia.additionalArgs"]
                @test any(
                    arg -> contains(arg, "--load") && contains(arg, ".julia-startup.jl"),
                    settings["julia.additionalArgs"],
                )

                # Test 7: Don't duplicate startup arg
                @test MCPRepl.configure_vscode_julia_args() == true
                settings = MCPRepl.read_vscode_settings()
                @test length(settings["julia.additionalArgs"]) == 3  # Should still be 3

            finally
                cd(original_dir)
            end
        end

        @testset "Julia Startup Script Management" begin
            original_dir = pwd()
            cd(temp_dir)

            try
                startup_path = MCPRepl.get_startup_script_path()

                # Test 1: Check non-existent startup script
                @test MCPRepl.has_startup_script() == false

                # Test 2: Install startup script with default port
                @test MCPRepl.install_startup_script(3000) == true
                @test isfile(startup_path)

                # Test 3: Verify script content
                content = read(startup_path, String)
                @test contains(content, "using MCPRepl")
                @test contains(content, "MCPRepl.start!")
                @test contains(content, "JULIA_MCP_PORT")
                @test contains(content, "3000")  # Default port

                # Test 4: Check has startup script
                @test MCPRepl.has_startup_script() == true

                # Test 5: Install with different port
                @test MCPRepl.install_startup_script(8080) == true
                content = read(startup_path, String)
                @test contains(content, "8080")

            finally
                cd(original_dir)
            end
        end

    finally
        # Cleanup: remove temp directory
        rm(temp_dir, recursive = true, force = true)
    end
end
