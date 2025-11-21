function repl_status_report()
    if !isdefined(Main, :Pkg)
        error("Expect Main.Pkg to be defined.")
    end
    Pkg = Main.Pkg

    try
        # Basic environment info
        println("🔍 Julia Environment Investigation")
        println("="^50)
        println()

        # Current directory
        println("📁 Current Directory:")
        println("   $(pwd())")
        println()

        # Active project
        active_proj = Base.active_project()
        println("📦 Active Project:")
        if active_proj !== nothing
            println("   Path: $active_proj")
            try
                project_data = Pkg.TOML.parsefile(active_proj)
                if haskey(project_data, "name")
                    println("   Name: $(project_data["name"])")
                else
                    println("   Name: $(basename(dirname(active_proj)))")
                end
                if haskey(project_data, "version")
                    println("   Version: $(project_data["version"])")
                end
            catch e
                println("   Error reading project info: $e")
            end
        else
            println("   No active project")
        end
        println()

        # Package status
        println("📚 Package Environment:")
        try
            # Get package status (suppress output)
            pkg_status = redirect_stdout(devnull) do
                Pkg.status(; mode = Pkg.PKGMODE_MANIFEST)
            end

            # Parse dependencies for development packages
            deps = Pkg.dependencies()
            dev_packages = Dict{String,String}()

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep && pkg_info.is_tracking_path
                    dev_packages[pkg_info.name] = pkg_info.source
                end
            end

            # Add current environment package if it's a development package
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_dir = dirname(active_proj)
                        # This is a development package since we're in its source
                        dev_packages[pkg_name] = pkg_dir
                    end
                catch
                    # Not a package, that's fine
                end
            end

            # Check if current environment is itself a package and collect its info
            current_env_package = nothing
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_version = get(project_data, "version", "dev")
                        pkg_uuid = project_data["uuid"]
                        current_env_package = (
                            name = pkg_name,
                            version = pkg_version,
                            uuid = pkg_uuid,
                            path = dirname(active_proj),
                        )
                    end
                catch
                    # Not a package environment, that's fine
                end
            end

            # Separate development packages from regular packages
            dev_deps = []
            regular_deps = []

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep
                    if haskey(dev_packages, pkg_info.name)
                        push!(dev_deps, pkg_info)
                    else
                        push!(regular_deps, pkg_info)
                    end
                end
            end

            # List development packages first (with current environment package at the top if applicable)
            has_dev_packages = !isempty(dev_deps) || current_env_package !== nothing
            if has_dev_packages
                println("   🔧 Development packages (tracked by Revise):")

                # Show current environment package first if it exists
                if current_env_package !== nothing
                    println(
                        "      $(current_env_package.name) v$(current_env_package.version) [CURRENT ENV] => $(current_env_package.path)",
                    )
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(current_env_package.name)
                        if pkg_dir !== nothing && pkg_dir != current_env_package.path
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end

                # Then show other development packages
                for pkg_info in dev_deps
                    # Skip if this is the same as the current environment package
                    if current_env_package !== nothing &&
                       pkg_info.name == current_env_package.name
                        continue
                    end
                    println(
                        "      $(pkg_info.name) v$(pkg_info.version) => $(dev_packages[pkg_info.name])",
                    )
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(pkg_info.name)
                        if pkg_dir !== nothing && pkg_dir != dev_packages[pkg_info.name]
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end
                println()
            end

            # List regular packages second
            if !isempty(regular_deps)
                println("   📦 Other packages in environment:")
                for pkg_info in regular_deps
                    println("      $(pkg_info.name) v$(pkg_info.version)")
                end
            end

            # Handle empty environment
            if isempty(deps) && current_env_package === nothing
                println("   No packages in environment")
            end

        catch e
            println("   Error getting package status: $e")
        end

        println()
        println("🔄 Revise.jl Status:")
        try
            if isdefined(Main, :Revise)
                println("   ✅ Revise.jl is loaded and active")
                println("   📝 Development packages will auto-reload on changes")
            else
                println("   ⚠️  Revise.jl is not loaded")
            end
        catch
            println("   ❓ Could not determine Revise.jl status")
        end

        return nothing

    catch e
        println("Error generating environment report: $e")
        return nothing
    end
end
