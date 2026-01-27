# Anki Sprite

Deploy Anki with REST API and MCP server to a Fly.io Sprite.

## Setup

```bash
cp .env.example .env
# Edit .env with your credentials
./make_sprite.sh
```

## Endpoints

- `/` - Anki web UI
- `/anki-api/*` - REST API
- `/mcp/*` - MCP server

## Auth

All endpoints require either:
- Basic auth (username/password from `.env`)
- `X-API-Key` header (API key from `.env`)
