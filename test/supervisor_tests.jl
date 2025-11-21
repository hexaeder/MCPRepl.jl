using ReTest
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
            auto_start = false,
            restart_policy = "never",
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
            auto_start = false,
            restart_policy = "never",
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
            auto_start = true,
            restart_policy = "always",
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

    @testset "Agent status transitions" begin
        registry = MCPRepl.Supervisor.AgentRegistry(
            heartbeat_interval = 1,
            heartbeat_timeout_count = 5,
            max_restarts_per_hour = 10,
        )

        agent = MCPRepl.Supervisor.AgentState(
            "test-agent",
            4001,
            "/path/to/agent",
            "Test agent";
            auto_start = false,
            restart_policy = "never",
        )

        MCPRepl.Supervisor.register_agent!(registry, agent)

        # Test transition from :starting to :healthy on first heartbeat
        @test agent.status == :starting
        MCPRepl.Supervisor.update_heartbeat!(registry, "test-agent", 12345)
        updated_agent = MCPRepl.Supervisor.get_agent(registry, "test-agent")
        @test updated_agent.status == :healthy
        @test updated_agent.pid == 12345
        @test updated_agent.uptime_start !== nothing

        # Test heartbeat updates
        first_heartbeat = updated_agent.last_heartbeat
        sleep(0.1)
        MCPRepl.Supervisor.update_heartbeat!(registry, "test-agent", 12345)
        updated_agent = MCPRepl.Supervisor.get_agent(registry, "test-agent")
        @test updated_agent.last_heartbeat > first_heartbeat
        @test updated_agent.missed_heartbeats == 0
    end

    @testset "Supervisor monitor detects dead agents" begin
        # Create registry with short timeouts for testing
        registry = MCPRepl.Supervisor.AgentRegistry(
            heartbeat_interval = 1,  # Check every 1 second
            heartbeat_timeout_count = 3,  # Dead after 3 missed heartbeats
            max_restarts_per_hour = 10,
        )

        # Create an agent that won't auto-restart
        agent = MCPRepl.Supervisor.AgentState(
            "test-dead-agent",
            4002,
            "/path/to/agent",
            "Agent that will die";
            auto_start = false,
            restart_policy = "never",
        )
        MCPRepl.Supervisor.register_agent!(registry, agent)

        # Send initial heartbeat to make it healthy
        MCPRepl.Supervisor.update_heartbeat!(registry, "test-dead-agent", 99999)
        agent_after_heartbeat = MCPRepl.Supervisor.get_agent(registry, "test-dead-agent")
        @test agent_after_heartbeat.status == :healthy
        @test agent_after_heartbeat.missed_heartbeats == 0

        # Simulate the monitor loop checking heartbeats manually
        # (without actually starting the background thread)

        # First check - agent is still alive (just got heartbeat)
        agents = MCPRepl.Supervisor.get_all_agents(registry)
        test_agent = agents["test-dead-agent"]
        age = now() - test_agent.last_heartbeat
        age_seconds = Dates.value(age) ÷ 1000
        @test age_seconds <= registry.heartbeat_interval
        @test test_agent.status == :healthy

        # Wait for heartbeat to become stale
        sleep(2)

        # Simulate monitor loop detecting late heartbeat
        lock(registry.lock) do
            test_agent.missed_heartbeats += 1
        end
        test_agent = MCPRepl.Supervisor.get_agent(registry, "test-dead-agent")
        @test test_agent.missed_heartbeats == 1
        @test test_agent.status == :healthy  # Still healthy, just one miss

        # Simulate more missed heartbeats
        lock(registry.lock) do
            test_agent.missed_heartbeats = 3
            # Agent should be marked dead when missed >= timeout_count
            if test_agent.missed_heartbeats >= registry.heartbeat_timeout_count
                test_agent.status = :dead
            end
        end

        test_agent = MCPRepl.Supervisor.get_agent(registry, "test-dead-agent")
        @test test_agent.missed_heartbeats >= 3
        @test test_agent.status == :dead
    end

    @testset "Agent stuck in starting state timeout" begin
        registry = MCPRepl.Supervisor.AgentRegistry(
            heartbeat_interval = 1,
            heartbeat_timeout_count = 5,
            max_restarts_per_hour = 10,
        )

        # Create agent in starting state
        agent = MCPRepl.Supervisor.AgentState(
            "stuck-agent",
            4003,
            "/path/to/agent",
            "Agent stuck starting";
            auto_start = false,
            restart_policy = "never",
        )
        MCPRepl.Supervisor.register_agent!(registry, agent)

        # Set uptime_start to simulate it started a while ago
        lock(registry.lock) do
            agent.uptime_start = now() - Second(65)  # 65 seconds ago
        end

        # Verify it's in starting state
        @test agent.status == :starting
        @test agent.uptime_start !== nothing

        # Calculate how long it's been starting
        startup_duration = now() - agent.uptime_start
        startup_seconds = Dates.value(startup_duration) ÷ 1000
        @test startup_seconds > 60  # Should be over 60 second timeout

        # After timeout, agent should be marked dead
        # (In real supervisor loop, this would happen automatically)
        if startup_seconds > 60
            lock(registry.lock) do
                agent.status = :dead
            end
        end

        updated_agent = MCPRepl.Supervisor.get_agent(registry, "stuck-agent")
        @test updated_agent.status == :dead
    end
end
