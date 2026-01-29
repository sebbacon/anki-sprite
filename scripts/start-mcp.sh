#!/bin/bash
# Anki MCP Server startup script
# Runs the MCP server via supergateway to expose SSE transport

cd /home/sprite/anki-mcp-server

# Source nvm to get correct PATH
export NVM_DIR="/.sprite/languages/node/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Wait for AnkiConnect to be available
echo "Waiting for AnkiConnect..."
for i in {1..60}; do
    if curl -sf -X POST http://localhost:8765 \
        -H "Content-Type: application/json" \
        -d '{"action":"version","version":6}' | grep -q '"result"'; then
        echo "AnkiConnect is ready"
        break
    fi
    echo "Waiting for AnkiConnect... ($i/60)"
    sleep 1
done

# Run supergateway wrapping the anki-mcp-server
exec npx supergateway \
    --stdio "node dist/index.js" \
    --port 8766 \
    --cors \
    --healthEndpoint /health \
    --logLevel info
