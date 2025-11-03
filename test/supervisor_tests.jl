using Test
using MCPRepl
using Dates

@testset "Supervisor Tests" begin
    @testset "uptime_string" begin
        # Test agent not started
        agent = MCPRepl.Supervisor.AgentState(
            "test",
            4000,
            "test_dir",
            "test agent";
            auto_start=false,
            restart_policy="never"
        )
        @test MCPRepl.Supervisor.uptime_string(agent) == "not started"

        # Test agent just started (< 1 minute)
        agent.uptime_start = now() - Second(30)
        uptime = MCPRepl.Supervisor.uptime_string(agent)
        @test uptime == "0m"

        # Test agent running for minutes
        agent.uptime_start = now() - Minute(5)
        uptime = MCPRepl.Supervisor.uptime_string(agent)
        @test uptime == "5m"

        # Test agent running for hours
        agent.uptime_start = now() - Hour(2) - Minute(30)
        uptime = MCPRepl.Supervisor.uptime_string(agent)
        @test uptime == "2h 30m"

        # Test edge case: exactly 1 hour
        agent.uptime_start = now() - Hour(1)
        uptime = MCPRepl.Supervisor.uptime_string(agent)
        @test uptime == "1h 0m"
    end

    @testset "heartbeat_age_string" begin
        agent = MCPRepl.Supervisor.AgentState(
            "test",
            4000,
            "test_dir",
            "test agent";
            auto_start=false,
            restart_policy="never"
        )

        # Test recent heartbeat (seconds)
        agent.last_heartbeat = now() - Second(30)
        age = MCPRepl.Supervisor.heartbeat_age_string(agent)
        @test occursin(r"\d+s ago", age)

        # Test heartbeat minutes ago
        agent.last_heartbeat = now() - Minute(5)
        age = MCPRepl.Supervisor.heartbeat_age_string(agent)
        @test occursin(r"\d+m ago", age)

        # Test heartbeat hours ago
        agent.last_heartbeat = now() - Hour(2)
        age = MCPRepl.Supervisor.heartbeat_age_string(agent)
        @test occursin(r"\d+h ago", age)
    end

    @testset "AgentState construction" begin
        agent = MCPRepl.Supervisor.AgentState(
            "test-agent",
            4001,
            "/path/to/agent",
            "Test agent description";
            auto_start=true,
            restart_policy="always"
        )

        @test agent.name == "test-agent"
        @test agent.port == 4001
        @test agent.directory == "/path/to/agent"
        @test agent.description == "Test agent description"
        @test agent.auto_start == true
        @test agent.restart_policy == "always"
        @test agent.status == :starting
        @test agent.pid === nothing
        @test agent.missed_heartbeats == 0
        @test agent.restarts == 0
    end
end
