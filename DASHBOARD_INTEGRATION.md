# Dashboard Integration Plan

## Goal
Integrate the React dashboard more tightly with the Julia proxy, making it easy to:
1. Package for distribution (no Node.js required for users)
2. Develop with hot reload
3. Start/stop dashboard from Julia code

## Implementation Strategy

### Phase 1: Build Production Bundle
1. Build React app to static files (`npm run build` → `dist/`)
2. Serve built files directly from Julia proxy
3. Update proxy to check for built files first, fall back to dev server

### Phase 2: Package Integration
1. Add `dashboard-ui/dist/` to git (or artifacts system)
2. Update proxy startup to automatically serve dashboard
3. Add dashboard management functions to Proxy module

### Phase 3: Development Mode
1. Add `dashboard_dev_mode()` function to detect Vite dev server
2. Proxy routes to localhost:3001 if dev server running
3. Otherwise serves built static files

### Phase 4: Julia Dashboard Controls
Add to Proxy module:
```julia
# Check dashboard status
Proxy.dashboard_status() -> Dict
  # Returns: running (bool), mode (dev/prod), url, port

# Start dashboard dev server (if in dev)
Proxy.start_dashboard_dev()
  # Runs npm run dev in background

# Stop dashboard dev server
Proxy.stop_dashboard_dev()

# Build dashboard (for developers)
Proxy.build_dashboard()
  # Runs npm run build

# Open dashboard in browser
Proxy.open_dashboard()
```

## File Structure
```
MCPRepl/
├── dashboard-ui/
│   ├── dist/              # Built files (included in package)
│   ├── src/               # React source (dev only)
│   ├── package.json
│   └── vite.config.ts
├── src/
│   ├── dashboard.jl       # Event logging
│   └── proxy.jl           # Serves dashboard
└── proxy.jl               # Launcher script
```

## Proxy Dashboard Serving Logic
```julia
function serve_dashboard(req)
    # 1. Check if dev server is running on 3001
    if is_dashboard_dev_running()
        # Proxy to Vite dev server (hot reload)
        return proxy_to_dev_server(req)
    end
    
    # 2. Serve built static files
    if isfile(joinpath(@__DIR__, "dashboard-ui", "dist", "index.html"))
        return serve_static_files(req)
    end
    
    # 3. Show helpful error message
    return dashboard_not_found_message()
end
```

## Distribution Considerations

### For Package Users (Julia General Registry)
- Include `dashboard-ui/dist/` in the package
- No Node.js required
- Dashboard "just works" when proxy starts

### For Developers
- Can run `npm run dev` for hot reload
- Proxy automatically detects and uses dev server
- Can build with `npm run build` when ready

### For Projects Using MCPRepl as Dependency
```julia
using MCPRepl

# Option 1: Use built-in dashboard (default)
MCPRepl.start!()  # Dashboard accessible at http://localhost:3001

# Option 2: No dashboard
MCPRepl.start!(dashboard=false)

# Option 3: Custom dashboard URL
MCPRepl.start!(dashboard_url="http://custom-dashboard:8080")
```

## Next Steps
1. ✅ Decide on approach
2. Build production React bundle
3. Update proxy to serve built files
4. Add dashboard management functions
5. Test packaging workflow
6. Document for users

## Open Questions
1. Should dashboard build be committed to git or generated on install?
   - **Recommendation**: Commit to git for simplicity
2. Should we support custom dashboards?
   - **Recommendation**: Yes, via URL configuration
3. Should dashboard be optional?
   - **Recommendation**: Yes, via `dashboard=false` flag
