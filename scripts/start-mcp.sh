#!/bin/bash
# Anki MCP Server startup script
# Runs the MCP server via supergateway to expose SSE transport

cd /home/sprite/anki-mcp-server

# Source nvm to get correct PATH
export NVM_DIR="/.sprite/languages/node/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Run supergateway wrapping the anki-mcp-server
exec npx supergateway \
    --stdio "node dist/index.js" \
    --port 8766 \
    --cors \
    --healthEndpoint /health \
    --logLevel info
