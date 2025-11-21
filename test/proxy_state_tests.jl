using ReTest
using Dates
using HTTP
using JSON

# Load proxy module
include("../src/proxy.jl")
using .Proxy

@testset "Proxy State Management" begin
    @testset "REPL Connection Structure" begin
        # Clear registry
        empty!(Proxy.REPL_REGISTRY)

        # Register a REPL
        Proxy.register_repl("test-repl", 3001; pid=12345)

        # Verify structure with new fields
        repl = Proxy.get_repl("test-repl")
        @test repl !== nothing
        @test repl.status == :ready
        @test repl.pending_requests isa Vector
        @test isempty(repl.pending_requests)
        @test repl.disconnect_time === nothing
        @test repl.missed_heartbeats == 0
    end

    @testset "Status Transitions" begin
        empty!(Proxy.REPL_REGISTRY)
        Proxy.register_repl("status-test", 3002; pid=12346)

        # ready -> disconnected
        lock(Proxy.REPL_REGISTRY_LOCK) do
            Proxy.REPL_REGISTRY["status-test"].status = :disconnected
            Proxy.REPL_REGISTRY["status-test"].disconnect_time = now()
        end
        repl = Proxy.get_repl("status-test")
        @test repl.status == :disconnected
        @test repl.disconnect_time !== nothing

        # disconnected -> reconnecting
        lock(Proxy.REPL_REGISTRY_LOCK) do
            Proxy.REPL_REGISTRY["status-test"].status = :reconnecting
        end
        repl = Proxy.get_repl("status-test")
        @test repl.status == :reconnecting

        # reconnecting -> ready (via update_repl_status)
        Proxy.update_repl_status("status-test", :ready)
        repl = Proxy.get_repl("status-test")
        @test repl.status == :ready
        @test repl.missed_heartbeats == 0
        @test repl.disconnect_time === nothing

        # ready -> stopped
        lock(Proxy.REPL_REGISTRY_LOCK) do
            Proxy.REPL_REGISTRY["status-test"].status = :stopped
        end
        repl = Proxy.get_repl("status-test")
        @test repl.status == :stopped
    end

    @testset "Request Buffering" begin
        empty!(Proxy.REPL_REGISTRY)
        Proxy.register_repl("buffer-test", 3003; pid=12347)

        # Simulate adding pending requests
        mock_request = Dict("method" => "test", "id" => 1)
        # Note: We can't create a real HTTP.Stream easily, so we test the structure

        lock(Proxy.REPL_REGISTRY_LOCK) do
            Proxy.REPL_REGISTRY["buffer-test"].status = :disconnected
            # Would normally add: push!(Proxy.REPL_REGISTRY["buffer-test"].pending_requests, (mock_request, mock_stream))
        end

        repl = Proxy.get_repl("buffer-test")
        @test repl.status == :disconnected
        @test isempty(repl.pending_requests)  # Empty because we didn't add mock stream
    end

    @testset "Heartbeat Timeout Detection" begin
        empty!(Proxy.REPL_REGISTRY)
        Proxy.register_repl("heartbeat-test", 3004; pid=12348)

        # Simulate old heartbeat
        lock(Proxy.REPL_REGISTRY_LOCK) do
            Proxy.REPL_REGISTRY["heartbeat-test"].last_heartbeat = now() - Second(20)
        end

        repl = Proxy.get_repl("heartbeat-test")
        time_since = now() - repl.last_heartbeat
        @test time_since > Second(15)
        @test repl.status == :ready  # Still ready until monitor runs

        # Manually trigger the timeout logic
        lock(Proxy.REPL_REGISTRY_LOCK) do
            if haskey(Proxy.REPL_REGISTRY, "heartbeat-test")
                Proxy.REPL_REGISTRY["heartbeat-test"].status = :disconnected
                Proxy.REPL_REGISTRY["heartbeat-test"].disconnect_time = now()
            end
        end

        repl = Proxy.get_repl("heartbeat-test")
        @test repl.status == :disconnected
        @test repl.disconnect_time !== nothing
    end

    @testset "Reconnection Recovery" begin
        empty!(Proxy.REPL_REGISTRY)
        Proxy.register_repl("recovery-test", 3005; pid=12349)

        # Simulate disconnection
        lock(Proxy.REPL_REGISTRY_LOCK) do
            Proxy.REPL_REGISTRY["recovery-test"].status = :disconnected
            Proxy.REPL_REGISTRY["recovery-test"].disconnect_time = now()
            Proxy.REPL_REGISTRY["recovery-test"].missed_heartbeats = 2
        end

        # Recover via update_repl_status(:ready)
        Proxy.update_repl_status("recovery-test", :ready)

        repl = Proxy.get_repl("recovery-test")
        @test repl.status == :ready
        @test repl.missed_heartbeats == 0
        @test repl.disconnect_time === nothing
    end

    @testset "Permanent Stop After Timeout" begin
        empty!(Proxy.REPL_REGISTRY)
        Proxy.register_repl("timeout-test", 3006; pid=12350)

        # Simulate long disconnection (>5 minutes)
        lock(Proxy.REPL_REGISTRY_LOCK) do
            Proxy.REPL_REGISTRY["timeout-test"].status = :disconnected
            Proxy.REPL_REGISTRY["timeout-test"].disconnect_time = now() - Minute(6)
        end

        repl = Proxy.get_repl("timeout-test")
        disconnect_duration = now() - repl.disconnect_time
        @test disconnect_duration > Minute(5)

        # Should be marked as stopped by error handler
        # (we test the condition, actual marking happens in route_to_repl_streaming)
    end

    @testset "Missed Heartbeats Counter" begin
        empty!(Proxy.REPL_REGISTRY)
        Proxy.register_repl("counter-test", 3007; pid=12351)

        repl = Proxy.get_repl("counter-test")
        @test repl.missed_heartbeats == 0

        # Increment counter via update_repl_status with error
        Proxy.update_repl_status("counter-test", :ready; error="Test error")
        repl = Proxy.get_repl("counter-test")
        @test repl.missed_heartbeats == 1

        # Reset counter via successful ready status
        Proxy.update_repl_status("counter-test", :ready)
        repl = Proxy.get_repl("counter-test")
        @test repl.missed_heartbeats == 0
    end
end
