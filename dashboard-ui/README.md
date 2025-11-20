# MCPRepl Dashboard (TypeScript/React)

Modern, professional dashboard for monitoring MCPRepl multi-agent sessions.

## Features

- **Real-time EKG Heartbeat Charts** - Using Recharts for smooth animations
- **TypeScript** - Full type safety
- **React 18** - Modern hooks and concurrent features
- **Vite** - Lightning fast dev server and builds
- **Professional Design** - Modern UI with animations and gradients

## Setup

```bash
cd dashboard-ui
npm install
```

## Development

```bash
# Start dev server (with proxy to Julia backend)
npm run dev

# Visit http://localhost:3001
```

The dev server proxies API requests to the Julia backend at `http://localhost:3000/dashboard/api/*`

## Build for Production

```bash
npm run build
```

This creates optimized assets in `dist/` that can be served by Julia's HTTP server.

## Integration with Julia

The Julia proxy server can serve the built React app:

```julia
# In src/dashboard.jl or proxy.jl
function handle_dashboard_request(request::HTTP.Request)
    # Serve built React app from dashboard-ui/dist/
    dist_path = joinpath(@__DIR__, "..", "dashboard-ui", "dist")
    # ... serve static files
end
```

## Architecture

```
dashboard-ui/
├── src/
│   ├── main.tsx          # Entry point
│   ├── App.tsx           # Main app component
│   ├── types.ts          # TypeScript types
│   ├── api.ts            # API client
│   └── components/
│       ├── AgentCard.tsx      # Agent status card
│       └── HeartbeatChart.tsx # EKG visualization
├── dist/                 # Built assets (served by Julia)
└── package.json
```

## Tech Stack

- **React 18** - UI framework
- **TypeScript** - Type safety
- **Recharts** - Chart library for EKG visualization
- **Vite** - Build tool and dev server
- **date-fns** - Date utilities
