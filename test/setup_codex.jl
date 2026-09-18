using Test
using MCPRepl
using TOML

@testset "Codex setup" begin
    mktempdir() do dir
        project = joinpath(dir, "project with spaces")
        codex_home = joinpath(dir, "codex home")
        paths = (; project_dir = project, codex_home)
        user_path = joinpath(codex_home, "config.toml")
        project_path = joinpath(project, ".codex", "config.toml")
        @test MCPRepl.codex_settings_path("user"; paths...) == user_path
        @test MCPRepl.codex_settings_path("project"; paths...) == project_path
        withenv("CODEX_HOME" => codex_home) do
            @test MCPRepl.codex_settings_path("user") == user_path
        end
        cd(dir) do
            @test MCPRepl.codex_settings_path("project") == joinpath(dir, ".codex", "config.toml")
        end
        @test_throws ArgumentError MCPRepl.configure_codex("local"; paths...)
        @test !isdir(project)
        @test MCPRepl.check_codex_status("project"; paths...) == :not_configured
        MCPRepl.remove_codex("project"; paths...)
        @test !isdir(project)

        mkpath(codex_home)
        original = """
        # Keep a copy of this comment in the backup.
        model = "example-model"
        [projects."/some/project"]
        trust_level = "trusted"
        [mcp_servers.other]
        command = "other-server"
        args = ["--flag", "path with spaces"]
        [mcp_servers.other.env]
        EXAMPLE = "value"
        [mcp_servers.julia-repl]
        url = "http://localhost:9999/mcp"
        enabled = false
        """
        write(user_path, original)
        @test MCPRepl.check_codex_status("user"; paths...) == :disabled
        @test MCPRepl.configure_codex("user"; paths...) == user_path
        @test read(user_path * ".bak", String) == original
        settings = TOML.parsefile(user_path)
        @test settings["model"] == "example-model"
        @test settings["projects"] == TOML.parse(original)["projects"]
        @test settings["mcp_servers"]["other"] == TOML.parse(original)["mcp_servers"]["other"]
        @test settings["mcp_servers"]["julia-repl"] == Dict(
            "command" => joinpath(pkgdir(MCPRepl), "mcp-julia-adapter"))
        @test MCPRepl.check_codex_status("user"; paths...) == :configured_script
        @test !isfile(project_path)

        MCPRepl.configure_codex("user"; paths...)
        @test TOML.parsefile(user_path) == settings
        @test MCPRepl.configure_codex("project"; paths...) == project_path
        @test MCPRepl.check_codex_status("project"; paths...) == :configured_script
        MCPRepl.remove_codex("project"; paths...)
        @test MCPRepl.check_codex_status("project"; paths...) == :not_configured
        @test TOML.parsefile(user_path) == settings
        MCPRepl.remove_codex("user"; paths...)
        delete!(settings["mcp_servers"], "julia-repl")
        @test TOML.parsefile(user_path) == settings
        backup = read(user_path * ".bak", String)
        MCPRepl.remove_codex("user"; paths...)
        @test read(user_path * ".bak", String) == backup

        for invalid in ("[broken", "mcp_servers = 42")
            write(user_path, invalid)
            @test MCPRepl.check_codex_status("user"; paths...) == :invalid_config
            @test_throws Exception MCPRepl.configure_codex("user"; paths...)
            @test read(user_path, String) == invalid
            @test_throws Exception MCPRepl.remove_codex("user"; paths...)
            @test read(user_path, String) == invalid
            @test read(user_path * ".bak", String) == backup
        end
    end
end
