# jst_dev

Gleam full-stack app with Lustre frontend and BEAM backend using SQLite.

## Requirements

- [Gleam](https://gleam.run/getting-started/installing/)
- Node.js (for frontend build)

## Development

```bash
# Build frontend and run server (serves frontend from backend)
make dev

# Run all checks (format + tests)
make check

# Build frontend only
make build-frontend
```

## Deployment (Fly.io)

```bash
# First-time setup
fly volumes create litefs --size 10
fly consul attach

# Deploy
fly deploy

# Preview environment
fly deploy --config fly.preview.toml
```

## Project Structure

```
shared/       # Shared types (Gleam, cross-target)
server_beam/  # Backend (Gleam/BEAM + SQLite + static file server)
jst_lustre/   # Frontend (Gleam/Lustre)
```

The server serves the frontend from `priv/static/`. Run `make build-frontend` to rebuild the frontend assets.
