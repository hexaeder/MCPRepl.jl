using Test
using MCPRepl
using HTTP
using JSON

@testset "Security Tests" begin
    # Setup - clean test directory
    test_dir = mktempdir()
    original_dir = pwd()
    
    try
        cd(test_dir)
        
        @testset "API Key Generation" begin
            key = MCPRepl.generate_api_key()
            @test startswith(key, "mcprepl_")
            @test length(key) == 48  # "mcprepl_" (8 chars) + 40 hex chars
            @test occursin(r"^mcprepl_[0-9a-f]{40}$", key)
            
            # Keys should be unique
            key2 = MCPRepl.generate_api_key()
            @test key != key2
        end
        
        @testset "Security Config - Save and Load" begin
            # Create config
            api_keys = [MCPRepl.generate_api_key()]
            allowed_ips = ["127.0.0.1", "::1", "192.168.1.1"]
            config = MCPRepl.SecurityConfig(:strict, api_keys, allowed_ips)
            
            # Save
            @test MCPRepl.save_security_config(config, test_dir)
            
            # Verify file exists
            config_path = MCPRepl.get_security_config_path(test_dir)
            @test isfile(config_path)
            
            # Load
            loaded = MCPRepl.load_security_config(test_dir)
            @test loaded !== nothing
            @test loaded.mode == :strict
            @test loaded.api_keys == api_keys
            @test loaded.allowed_ips == allowed_ips
            
            # Verify .gitignore was created/updated
            gitignore_path = joinpath(test_dir, ".gitignore")
            @test isfile(gitignore_path)
            gitignore_content = read(gitignore_path, String)
            @test contains(gitignore_content, ".mcprepl")
        end
        
        @testset "API Key Validation" begin
            valid_key = MCPRepl.generate_api_key()
            invalid_key = "invalid_key_123"
            
            # Strict mode
            config_strict = MCPRepl.SecurityConfig(:strict, [valid_key], ["127.0.0.1"])
            @test MCPRepl.validate_api_key(valid_key, config_strict)
            @test !MCPRepl.validate_api_key(invalid_key, config_strict)
            @test !MCPRepl.validate_api_key("", config_strict)
            
            # Relaxed mode
            config_relaxed = MCPRepl.SecurityConfig(:relaxed, [valid_key], ["127.0.0.1"])
            @test MCPRepl.validate_api_key(valid_key, config_relaxed)
            @test !MCPRepl.validate_api_key(invalid_key, config_relaxed)
            
            # Lax mode (no key required)
            config_lax = MCPRepl.SecurityConfig(:lax, String[], ["127.0.0.1"])
            @test MCPRepl.validate_api_key("", config_lax)
            @test MCPRepl.validate_api_key("anything", config_lax)
        end
        
        @testset "IP Validation" begin
            config_strict = MCPRepl.SecurityConfig(:strict, ["key"], ["127.0.0.1", "192.168.1.1"])
            @test MCPRepl.validate_ip("127.0.0.1", config_strict)
            @test MCPRepl.validate_ip("192.168.1.1", config_strict)
            @test !MCPRepl.validate_ip("10.0.0.1", config_strict)
            
            # Relaxed mode (any IP)
            config_relaxed = MCPRepl.SecurityConfig(:relaxed, ["key"], ["127.0.0.1"])
            @test MCPRepl.validate_ip("127.0.0.1", config_relaxed)
            @test MCPRepl.validate_ip("10.0.0.1", config_relaxed)
            @test MCPRepl.validate_ip("8.8.8.8", config_relaxed)
            
            # Lax mode (localhost only)
            config_lax = MCPRepl.SecurityConfig(:lax, String[], String[])
            @test MCPRepl.validate_ip("127.0.0.1", config_lax)
            @test MCPRepl.validate_ip("::1", config_lax)
            @test MCPRepl.validate_ip("localhost", config_lax)
            @test !MCPRepl.validate_ip("192.168.1.1", config_lax)
        end
        
        @testset "Quick Setup" begin
            # Remove any existing config
            config_dir = joinpath(test_dir, ".mcprepl")
            if isdir(config_dir)
                rm(config_dir; recursive=true)
            end
            
            # Quick setup with lax mode (default port 3000)
            config = MCPRepl.quick_setup(:lax, 3000, test_dir)
            @test config.mode == :lax
            @test length(config.api_keys) == 0  # No keys in lax mode
            @test "127.0.0.1" in config.allowed_ips
            
            # Verify it was saved
            loaded = MCPRepl.load_security_config(test_dir)
            @test loaded !== nothing
            @test loaded.mode == :lax
        end
        
        @testset "Security Management Functions" begin
            # Start fresh
            config_dir = joinpath(test_dir, ".mcprepl")
            if isdir(config_dir)
                rm(config_dir; recursive=true)
            end
            
            # Create initial config (default port 3000)
            MCPRepl.quick_setup(:strict, 3000, test_dir)
            
            # Generate new key
            key = MCPRepl.add_api_key!(test_dir)
            @test startswith(key, "mcprepl_")
            loaded = MCPRepl.load_security_config(test_dir)
            @test key in loaded.api_keys
            
            # Remove key
            @test MCPRepl.remove_api_key!(key, test_dir)
            loaded = MCPRepl.load_security_config(test_dir)
            @test !(key in loaded.api_keys)
            
            # Add IP
            @test MCPRepl.add_allowed_ip!("10.0.0.1", test_dir)
            loaded = MCPRepl.load_security_config(test_dir)
            @test "10.0.0.1" in loaded.allowed_ips
            
            # Remove IP
            @test MCPRepl.remove_allowed_ip!("10.0.0.1", test_dir)
            loaded = MCPRepl.load_security_config(test_dir)
            @test !("10.0.0.1" in loaded.allowed_ips)
            
            # Change mode
            @test MCPRepl.change_security_mode!(:relaxed, test_dir)
            loaded = MCPRepl.load_security_config(test_dir)
            @test loaded.mode == :relaxed
        end
        
        @testset "Server Authentication" begin
            # Create security config
            test_port = 13100
            api_key = MCPRepl.generate_api_key()
            security_config = MCPRepl.SecurityConfig(:strict, [api_key], ["127.0.0.1", "::1"])
            MCPRepl.save_security_config(security_config, test_dir)
            
            # Create simple test tool
            test_tool = MCPRepl.MCPTool(
                "test_echo",
                "Echo back input",
                MCPRepl.text_parameter("message", "Message to echo"),
                args -> get(args, "message", ""),
            )
            
            # Start server with security
            server = MCPRepl.start_mcp_server(
                [test_tool],
                test_port;
                verbose = false,
                security_config = security_config,
            )
            
            # Give server plenty of time to start and stabilize
            sleep(3.0)
            
            # Wait for server to be ready with robust retry logic
            # Use valid auth from the start to avoid connection resets
            server_ready = false
            last_error = nothing
            for attempt in 1:40
                try
                    # Make a simple POST request with valid auth to test connectivity
                    test_body = JSON.json(Dict("jsonrpc" => "2.0", "id" => 0, "method" => "tools/list"))
                    response = HTTP.post(
                        "http://localhost:$test_port/",
                        [
                            "Content-Type" => "application/json",
                            "Authorization" => "Bearer $api_key"
                        ],
                        test_body;
                        status_exception = false,
                        readtimeout = 5,
                        retry = false,
                        connect_timeout = 5
                    )
                    # Any response (even error) means server is ready
                    if response.status >= 100
                        server_ready = true
                        break
                    end
                catch e
                    last_error = e
                    sleep(0.5)
                end
            end
            
            if !server_ready
                @error "Server did not become ready after 20 seconds" last_error
            end
            @test server_ready
            
            # Now run the actual authentication tests
            request_body = JSON.json(
                Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "test_echo",
                        "arguments" => Dict("message" => "hello"),
                    ),
                ),
            )
            
            # Test 1: No API key - should fail with 401
            response = HTTP.post(
                "http://localhost:$test_port/",
                ["Content-Type" => "application/json"],
                request_body;
                status_exception = false,
                readtimeout = 10,
                retry = false,
            )
            
            @test response.status == 401  # Unauthorized
            body = JSON.parse(String(response.body))
            @test contains(body["error"], "Unauthorized")
            
            # Test 2: Invalid API key - should fail with 403
            response = HTTP.post(
                "http://localhost:$test_port/",
                [
                    "Content-Type" => "application/json",
                    "Authorization" => "Bearer invalid_key",
                ],
                request_body;
                status_exception = false,
                readtimeout = 10,
                retry = false,
            )
            
            @test response.status == 403  # Forbidden
            body = JSON.parse(String(response.body))
            @test contains(body["error"], "Forbidden")
            
            # Test 3: Valid API key - should succeed with 200
            response = HTTP.post(
                "http://localhost:$test_port/",
                [
                    "Content-Type" => "application/json",
                    "Authorization" => "Bearer $api_key",
                ],
                request_body;
                status_exception = false,
                readtimeout = 10,
                retry = false,
            )
            
            @test response.status == 200
            body = JSON.parse(String(response.body))
            @test haskey(body, "result")
            @test body["result"]["content"][1]["text"] == "hello"
            
            # Clean up
            MCPRepl.stop_mcp_server(server)
            sleep(0.2)
        end
        
    finally
        cd(original_dir)
        rm(test_dir; recursive=true, force=true)
    end
end
