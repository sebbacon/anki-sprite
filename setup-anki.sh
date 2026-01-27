#!/bin/bash
# Anki Docker Setup Script
# This script sets up the complete Anki Docker environment with Sprite services
# Run with: bash setup-anki.sh
#
# This script is fully self-contained and creates all necessary files.
# Secrets are loaded from .env file (see .env.example for template)

set -e

echo "=== Anki Docker Setup ==="
echo ""

# ============================================================================
# Step 0: Load Environment Variables
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "Please copy .env.example to .env and configure your secrets."
    exit 1
fi

# Validate required environment variables
if [ -z "$ANKI_AUTH_USERNAME" ] || [ -z "$ANKI_AUTH_PASSWORD" ] || [ -z "$ANKI_API_KEY" ]; then
    echo "ERROR: Missing required environment variables."
    echo "Please ensure .env contains: ANKI_AUTH_USERNAME, ANKI_AUTH_PASSWORD, and ANKI_API_KEY"
    exit 1
fi

echo "Environment variables loaded successfully."
echo ""

# ============================================================================
# Step 1: System Setup
# ============================================================================

echo "Step 1: Update system packages..."
sudo apt update

echo ""
echo "Step 2: Install Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
else
    echo "Docker already installed, skipping..."
fi

echo ""
echo "Step 3: Add current user to docker group..."
sudo usermod -aG docker $USER || true

echo ""
echo "Step 4: Fix home directory ownership and create Anki working directory..."
# On fresh Sprites, /home/sprite may be owned by ubuntu - fix this
sudo chown -R sprite:sprite /home/sprite 2>/dev/null || true
mkdir -p ~/anki
cd ~/anki

# ============================================================================
# Step 4b: Generate password hash from plaintext password
# ============================================================================

echo ""
echo "Step 4b: Generating bcrypt hash for password..."
# Pull caddy image first so we can use it to generate the hash
sudo docker pull caddy:alpine

# Generate bcrypt hash using caddy (escaping special characters for shell)
ANKI_AUTH_PASSWORD_HASH=$(sudo docker run --rm caddy:alpine caddy hash-password --plaintext "${ANKI_AUTH_PASSWORD}")
echo "Password hash generated successfully."

# ============================================================================
# Step 5: Create Configuration Files
# ============================================================================

echo ""
echo "Step 5a: Creating docker-compose.yml..."
cat > ~/anki/docker-compose.yml << 'EOF'
services:
  caddy:
    image: caddy:alpine
    ports:
      - 3000:3000  # Web UI (with basic auth)
      - 3001:3001  # MCP Server (with basic auth)
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./mcp-schema.json:/etc/caddy/mcp-schema.json:ro
      - ./loading.html:/etc/caddy/loading.html:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - anki-desktop

  anki-desktop:
    image: mlcivilengineer/anki-desktop-docker:main
    environment:
      - PUID=1000
      - PGID=1000
      # Uncomment the following lines to enable CJK font support
      # - DOCKER_MODS=linuxserver/mods:universal-package-install
      # - INSTALL_PACKAGES=language-pack-zh-hans|fonts-arphic-ukai|fonts-arphic-uming|fonts-ipafont-mincho|fonts-ipafont-gothic|fonts-unfonts-core
    volumes:
      - ./anki_data:/config
    ports:
      - 8765:8765  # AnkiConnect API (no auth)
    # Note: port 3000 is now internal-only, accessed via Caddy
EOF

echo ""
echo "Step 5b: Creating Caddyfile with authentication and error handling..."
cat > ~/anki/Caddyfile << EOF
# ============================================================================
# AUTHENTICATION CREDENTIALS - DO NOT CHANGE
# ============================================================================
# These credentials are used by external integrations and changing them
# will break automated systems. Contact the system administrator before
# making any modifications.
#
# Basic Auth:
#   Username: ${ANKI_AUTH_USERNAME}
#   Password: (see .env file)
#
# API Key (use as X-API-Key header):
#   (see .env file)
#
# ============================================================================

:3000 {
    # API Key authentication (checked first)
    @apikey header X-API-Key ${ANKI_API_KEY}

    # Basic auth for requests without valid API key
    @nokey not header X-API-Key ${ANKI_API_KEY}
    basicauth @nokey {
        ${ANKI_AUTH_USERNAME} ${ANKI_AUTH_PASSWORD_HASH}
    }

    # Error handling - different responses for API vs browser requests
    handle_errors {
        # API endpoints get JSON error response
        @api_startup expression {err.status_code} in [502, 503, 504] && {http.request.orig_uri.path}.startsWith("/anki-api/")
        handle @api_startup {
            header Content-Type application/json
            respond `{"error": "Service starting up. Please retry in a few seconds.", "status": "starting", "code": 503}` 503
        }

        # MCP endpoints get JSON error response
        @mcp_startup expression {err.status_code} in [502, 503, 504] && {http.request.orig_uri.path}.startsWith("/mcp/")
        handle @mcp_startup {
            header Content-Type application/json
            respond `{"error": "Service starting up. Please retry in a few seconds.", "status": "starting", "code": 503}` 503
        }

        # Browser/UI requests get friendly loading page
        @ui_startup expression {err.status_code} in [502, 503, 504]
        handle @ui_startup {
            root * /etc/caddy
            rewrite * /loading.html
            file_server
        }

        # Default error response for other errors
        respond "{err.status_code} {err.status_text}"
    }

    # Startup health check - proxies to AnkiConnect to verify Anki is fully loaded
    handle /startup/health {
        reverse_proxy anki-desktop:8765
    }

    # Startup loading page - can be accessed directly for testing
    handle /startup/loading {
        root * /etc/caddy
        rewrite * /loading.html
        file_server
    }

    # MCP schema endpoint (static file)
    handle /mcp/schema.json {
        root * /etc/caddy
        rewrite * /mcp-schema.json
        file_server
    }

    # MCP Server endpoints (SSE transport)
    handle /mcp/* {
        uri strip_prefix /mcp
        reverse_proxy host.docker.internal:8766
    }

    # Anki REST API (OpenAPI-compatible for ChatGPT)
    handle /anki-api/* {
        uri strip_prefix /anki-api
        reverse_proxy host.docker.internal:8767
    }

    # Anki Desktop UI (default)
    handle {
        reverse_proxy anki-desktop:3000
    }
}

:3001 {
    # API Key authentication (checked first)
    @apikey header X-API-Key ${ANKI_API_KEY}

    # Basic auth for requests without valid API key
    @nokey not header X-API-Key ${ANKI_API_KEY}
    basicauth @nokey {
        ${ANKI_AUTH_USERNAME} ${ANKI_AUTH_PASSWORD_HASH}
    }

    reverse_proxy host.docker.internal:8766
}
EOF

echo ""
echo "Step 5c: Creating startup loading page..."
cat > ~/anki/loading.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Anki - Starting Up</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
        }
        .container { text-align: center; padding: 2rem; }
        .logo { font-size: 4rem; margin-bottom: 1.5rem; }
        h1 { font-size: 1.8rem; font-weight: 500; margin-bottom: 1rem; }
        .status { font-size: 1rem; color: #8892b0; margin-bottom: 2rem; }
        .spinner {
            width: 50px; height: 50px;
            border: 3px solid rgba(255,255,255,0.1);
            border-top-color: #64ffda;
            border-radius: 50%;
            animation: spin 1s linear infinite;
            margin: 0 auto 1.5rem;
        }
        @keyframes spin { to { transform: rotate(360deg); } }
        .progress-bar {
            width: 300px; height: 4px;
            background: rgba(255,255,255,0.1);
            border-radius: 2px;
            overflow: hidden;
            margin: 0 auto;
        }
        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #64ffda, #48bb78);
            width: 0%;
            transition: width 0.5s ease;
        }
        .detail { font-size: 0.85rem; color: #5a6a8a; margin-top: 1.5rem; }
        .ready .checkmark { display: block; }
        .ready .spinner { display: none; }
        .checkmark { display: none; font-size: 3rem; color: #64ffda; margin-bottom: 1rem; }
    </style>
</head>
<body>
    <div class="container" id="container">
        <div class="logo">📚</div>
        <div class="spinner" id="spinner"></div>
        <div class="checkmark" id="checkmark">✓</div>
        <h1 id="title">Anki is starting up...</h1>
        <p class="status" id="status">Please wait while the application loads</p>
        <div class="progress-bar"><div class="progress-fill" id="progress"></div></div>
        <p class="detail" id="detail">Checking service status...</p>
    </div>
    <script>
        const stages = [
            { name: 'Initializing Docker...', progress: 20 },
            { name: 'Starting container...', progress: 40 },
            { name: 'Loading Anki desktop...', progress: 60 },
            { name: 'Waiting for AnkiConnect...', progress: 80 },
            { name: 'Ready!', progress: 100 }
        ];
        let currentStage = 0, checkCount = 0;
        const maxChecks = 120;
        const progress = document.getElementById('progress');
        const detail = document.getElementById('detail');
        const title = document.getElementById('title');
        const status = document.getElementById('status');
        const container = document.getElementById('container');

        function updateProgress() {
            const stageIndex = Math.min(Math.floor(checkCount / 6), stages.length - 2);
            if (stageIndex > currentStage) currentStage = stageIndex;
            detail.textContent = stages[currentStage].name;
            const baseProgress = stages[currentStage].progress - 20;
            progress.style.width = (baseProgress + Math.min((checkCount % 6) * 3, 18)) + '%';
        }

        async function checkHealth() {
            checkCount++;
            if (checkCount > maxChecks) {
                detail.textContent = 'Taking longer than expected. Please refresh.';
                return;
            }
            updateProgress();
            try {
                const response = await fetch('/startup/health', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'version', version: 6 })
                });
                if (response.ok) {
                    const data = await response.json();
                    if (data.result) { showReady(); return; }
                }
            } catch (e) {}
            setTimeout(checkHealth, 1000);
        }

        function showReady() {
            container.classList.add('ready');
            title.textContent = 'Anki is ready!';
            status.textContent = 'Redirecting...';
            detail.textContent = '';
            progress.style.width = '100%';
            setTimeout(() => window.location.reload(), 500);
        }
        checkHealth();
    </script>
</body>
</html>
EOF

echo ""
echo "Step 5d: Creating MCP schema file..."
cat > ~/anki/mcp-schema.json << 'EOF'
{
  "tools": [
    {"name": "list_decks", "description": "List all available Anki decks", "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "create_deck", "description": "Create a new Anki deck", "inputSchema": {"type": "object", "properties": {"name": {"type": "string", "description": "Name of the deck to create"}}, "required": ["name"]}},
    {"name": "get_note_type_info", "description": "Get detailed structure of a note type", "inputSchema": {"type": "object", "properties": {"modelName": {"type": "string", "description": "Name of the note type/model"}, "includeCss": {"type": "boolean", "description": "Whether to include CSS information"}}, "required": ["modelName"]}},
    {"name": "create_note", "description": "Create a new note (LLM Should call get_note_type_info first)", "inputSchema": {"type": "object", "properties": {"type": {"type": "string", "description": "Note type"}, "deck": {"type": "string", "description": "Deck name"}, "fields": {"type": "object", "description": "Custom fields for the note", "additionalProperties": true}, "allowDuplicate": {"type": "boolean", "description": "Whether to allow duplicate notes"}, "tags": {"type": "array", "items": {"type": "string"}, "description": "Tags for the note"}}, "required": ["type", "deck", "fields"]}},
    {"name": "batch_create_notes", "description": "Create multiple notes at once", "inputSchema": {"type": "object", "properties": {"notes": {"type": "array", "items": {"type": "object", "properties": {"type": {"type": "string"}, "deck": {"type": "string"}, "fields": {"type": "object", "additionalProperties": true}, "tags": {"type": "array", "items": {"type": "string"}}}, "required": ["type", "deck", "fields"]}}, "allowDuplicate": {"type": "boolean"}, "stopOnError": {"type": "boolean"}}, "required": ["notes"]}},
    {"name": "search_notes", "description": "Search for notes using Anki query syntax", "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "Anki search query"}}, "required": ["query"]}},
    {"name": "get_note_info", "description": "Get detailed information about a note", "inputSchema": {"type": "object", "properties": {"noteId": {"type": "number", "description": "Note ID"}}, "required": ["noteId"]}},
    {"name": "update_note", "description": "Update an existing note", "inputSchema": {"type": "object", "properties": {"id": {"type": "number", "description": "Note ID"}, "fields": {"type": "object", "description": "Fields to update"}, "tags": {"type": "array", "items": {"type": "string"}, "description": "New tags for the note"}}, "required": ["id", "fields"]}},
    {"name": "delete_note", "description": "Delete a note", "inputSchema": {"type": "object", "properties": {"noteId": {"type": "number", "description": "Note ID to delete"}}, "required": ["noteId"]}},
    {"name": "store_media_file", "description": "Store a file in Anki's media collection", "inputSchema": {"type": "object", "properties": {"filename": {"type": "string", "description": "Filename to write"}, "data": {"type": "string", "description": "Base64-encoded contents"}, "filePath": {"type": "string", "description": "Path to a local file"}}, "required": ["filename"]}},
    {"name": "retrieve_media_file", "description": "Fetch a media file as base64-encoded text", "inputSchema": {"type": "object", "properties": {"filename": {"type": "string", "description": "Media filename to retrieve"}}, "required": ["filename"]}},
    {"name": "delete_media_file", "description": "Delete a file from Anki's media folder", "inputSchema": {"type": "object", "properties": {"filename": {"type": "string", "description": "Media filename to delete"}}, "required": ["filename"]}},
    {"name": "list_note_types", "description": "List all available note types", "inputSchema": {"type": "object", "properties": {}, "required": []}},
    {"name": "create_note_type", "description": "Create a new note type", "inputSchema": {"type": "object", "properties": {"name": {"type": "string", "description": "Name of the new note type"}, "fields": {"type": "array", "items": {"type": "string"}, "description": "Field names"}, "css": {"type": "string", "description": "CSS styling"}, "templates": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}, "front": {"type": "string"}, "back": {"type": "string"}}, "required": ["name", "front", "back"]}, "description": "Card templates"}}, "required": ["name", "fields", "templates"]}}
  ]
}
EOF

echo ""
echo "Step 5e: Creating OpenAPI spec for REST API..."
cat > ~/anki/openapi-anki.json << 'EOF'
{
  "openapi": "3.1.0",
  "info": {
    "title": "AnkiConnect API",
    "description": "API for interacting with Anki flashcard application via AnkiConnect",
    "version": "6.0.0"
  },
  "servers": [{"url": "/anki-api"}],
  "paths": {
    "/deckNames": {"get": {"operationId": "listDecks", "summary": "List all deck names", "responses": {"200": {"description": "List of deck names", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": "array", "items": {"type": "string"}}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/createDeck": {"post": {"operationId": "createDeck", "summary": "Create a new deck", "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object", "required": ["deck"], "properties": {"deck": {"type": "string"}}}}}}, "responses": {"200": {"description": "Deck ID", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": "integer"}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/modelNames": {"get": {"operationId": "listNoteTypes", "summary": "List all note type names", "responses": {"200": {"description": "List of note types", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": "array", "items": {"type": "string"}}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/modelFieldNames": {"post": {"operationId": "getNoteTypeFields", "summary": "Get field names for a note type", "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object", "required": ["modelName"], "properties": {"modelName": {"type": "string"}}}}}}, "responses": {"200": {"description": "List of field names", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": "array", "items": {"type": "string"}}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/addNote": {"post": {"operationId": "createNote", "summary": "Create a new note", "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object", "required": ["note"], "properties": {"note": {"type": "object", "required": ["deckName", "modelName", "fields"], "properties": {"deckName": {"type": "string"}, "modelName": {"type": "string"}, "fields": {"type": "object", "additionalProperties": {"type": "string"}}, "tags": {"type": "array", "items": {"type": "string"}}}}}}}}}, "responses": {"200": {"description": "Note ID", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": "integer"}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/findNotes": {"post": {"operationId": "searchNotes", "summary": "Search for notes", "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object", "required": ["query"], "properties": {"query": {"type": "string"}}}}}}, "responses": {"200": {"description": "Array of note IDs", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": "array", "items": {"type": "integer"}}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/notesInfo": {"post": {"operationId": "getNotesInfo", "summary": "Get note details", "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object", "required": ["notes"], "properties": {"notes": {"type": "array", "items": {"type": "integer"}}}}}}}, "responses": {"200": {"description": "Array of note details", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": "array", "items": {"type": "object"}}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/updateNoteFields": {"post": {"operationId": "updateNote", "summary": "Update a note", "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object", "required": ["note"], "properties": {"note": {"type": "object", "required": ["id", "fields"], "properties": {"id": {"type": "integer"}, "fields": {"type": "object", "additionalProperties": {"type": "string"}}}}}}}}}, "responses": {"200": {"description": "Success", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": ["string", "null"]}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/deleteNotes": {"post": {"operationId": "deleteNotes", "summary": "Delete notes", "requestBody": {"required": true, "content": {"application/json": {"schema": {"type": "object", "required": ["notes"], "properties": {"notes": {"type": "array", "items": {"type": "integer"}}}}}}}, "responses": {"200": {"description": "Success", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": ["string", "null"]}, "error": {"type": ["string", "null"]}}}}}}}}},
    "/sync": {"post": {"operationId": "syncWithAnkiWeb", "summary": "Sync with AnkiWeb", "responses": {"200": {"description": "Success", "content": {"application/json": {"schema": {"type": "object", "properties": {"result": {"type": ["string", "null"]}, "error": {"type": ["string", "null"]}}}}}}}}}
  },
  "components": {"securitySchemes": {"apiKey": {"type": "apiKey", "in": "header", "name": "X-API-Key"}}},
  "security": [{"apiKey": []}]
}
EOF

echo ""
echo "Step 5f: Creating REST API proxy..."
cat > ~/anki/anki-rest-proxy.js << 'JSEOF'
#!/usr/bin/env node
/**
 * REST API proxy for AnkiConnect
 * Translates REST-style endpoints to AnkiConnect's JSON-RPC format
 */

const http = require('http');

const ANKI_CONNECT_URL = 'http://localhost:8765';
const PORT = 8767;

// Map REST endpoints to AnkiConnect actions
const ENDPOINT_MAP = {
  'GET /deckNames': { action: 'deckNames' },
  'POST /createDeck': { action: 'createDeck', paramKey: 'deck' },
  'GET /modelNames': { action: 'modelNames' },
  'POST /modelFieldNames': { action: 'modelFieldNames', paramKey: 'modelName' },
  'POST /addNote': { action: 'addNote', paramKey: 'note' },
  'POST /addNotes': { action: 'addNotes', paramKey: 'notes' },
  'POST /findNotes': { action: 'findNotes', paramKey: 'query' },
  'POST /notesInfo': { action: 'notesInfo', paramKey: 'notes' },
  'POST /updateNoteFields': { action: 'updateNoteFields', paramKey: 'note' },
  'POST /deleteNotes': { action: 'deleteNotes', paramKey: 'notes' },
  'POST /sync': { action: 'sync' },
};

async function callAnkiConnect(action, params = {}) {
  const body = JSON.stringify({ action, version: 6, params });
  return new Promise((resolve, reject) => {
    const req = http.request(ANKI_CONNECT_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch (e) { reject(new Error('Invalid JSON from AnkiConnect')); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function parseBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      if (!body) return resolve({});
      try { resolve(JSON.parse(body)); }
      catch (e) { reject(new Error('Invalid JSON in request body')); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key, Authorization');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;

  if (path === '/health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }

  if (path === '/openapi.json') {
    try {
      const fs = require('fs');
      const spec = fs.readFileSync('/home/sprite/anki/openapi-anki.json', 'utf8');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(spec);
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Failed to load OpenAPI spec' }));
    }
    return;
  }

  const endpointKey = `${req.method} ${path}`;
  const endpoint = ENDPOINT_MAP[endpointKey];

  if (!endpoint) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: `Unknown endpoint: ${endpointKey}` }));
    return;
  }

  try {
    let params = {};
    if (req.method === 'POST') {
      const body = await parseBody(req);
      if (endpoint.paramKey) {
        params = { [endpoint.paramKey]: body[endpoint.paramKey] || body };
      } else {
        params = body;
      }
    }
    const result = await callAnkiConnect(endpoint.action, params);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(result));
  } catch (e) {
    if (e.code === 'ECONNREFUSED' || e.code === 'ENOTFOUND' || e.code === 'ETIMEDOUT') {
      res.writeHead(503, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        error: 'AnkiConnect is not available. Anki may still be starting up.',
        status: 'unavailable',
        code: 503
      }));
    } else {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message || 'Unknown error occurred' }));
    }
  }
});

server.listen(PORT, () => {
  console.log(`Anki REST API proxy listening on port ${PORT}`);
  console.log(`OpenAPI spec available at http://localhost:${PORT}/openapi.json`);
});
JSEOF
chmod +x ~/anki/anki-rest-proxy.js

echo ""
echo "Step 5g: Creating REST API startup script..."
cat > ~/anki/start-rest-proxy.sh << 'EOF'
#!/bin/bash
# Anki REST API proxy startup script

cd /home/sprite/anki

# Source nvm to get correct PATH
export NVM_DIR="/.sprite/languages/node/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

exec node /home/sprite/anki/anki-rest-proxy.js
EOF
chmod +x ~/anki/start-rest-proxy.sh

# ============================================================================
# Step 6: Create Sprite Service Scripts
# ============================================================================

echo ""
echo "Step 6a: Create Docker daemon wrapper script..."
cat > ~/anki/start-dockerd.sh << 'EOF'
#!/bin/bash
exec sudo /usr/bin/dockerd --group docker
EOF
chmod +x ~/anki/start-dockerd.sh

echo ""
echo "Step 6b: Create Anki management script..."
cat > ~/anki/manage-anki.sh << 'EOF'
#!/bin/bash
# Anki Docker Container Manager
# This script ensures Docker is running and starts the Anki container

cd /home/sprite/anki

# Wait for dockerd to be ready
for i in {1..30}; do
    if sudo docker ps > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Start Anki container
exec sudo docker compose up --no-log-prefix
EOF
chmod +x ~/anki/manage-anki.sh

# ============================================================================
# Step 7: Create Sprite Services
# ============================================================================

echo ""
echo "Step 7a: Create Sprite service for Docker daemon..."
sprite-env services create dockerd --cmd /home/sprite/anki/start-dockerd.sh 2>/dev/null || echo "Service dockerd may already exist"

echo ""
echo "Step 7b: Wait for Docker to be ready..."
sleep 5

echo ""
echo "Step 7c: Pull Anki Docker image..."
cd ~/anki
sudo docker compose pull

echo ""
echo "Step 7d: Create Anki data directory..."
mkdir -p ~/anki/anki_data

echo ""
echo "Step 7e: Start Anki container..."
sudo docker compose up -d

echo ""
echo "Step 7f: Create Sprite service for Anki with HTTP port..."
sprite-env services create anki --cmd /home/sprite/anki/manage-anki.sh --needs dockerd --http-port 3000 2>/dev/null || echo "Service anki may already exist"

# ============================================================================
# Step 8: Install AnkiConnect Addon
# ============================================================================

echo ""
echo "Step 8: Install AnkiConnect addon..."
mkdir -p ~/anki/anki_data/.local/share/Anki2/addons21/2055492159
if [ ! -d /tmp/anki-connect ]; then
    git clone https://github.com/FooSoft/anki-connect.git /tmp/anki-connect 2>/dev/null || true
fi
if [ -d /tmp/anki-connect/plugin ]; then
    cp -r /tmp/anki-connect/plugin/* ~/anki/anki_data/.local/share/Anki2/addons21/2055492159/
fi
cat > ~/anki/anki_data/.local/share/Anki2/addons21/2055492159/config.json << 'EOF'
{
    "apiKey": null,
    "apiLogPath": null,
    "webBindAddress": "0.0.0.0",
    "webBindPort": 8765,
    "webCorsOriginList": ["*"],
    "ignoreOriginList": []
}
EOF
sudo chown -R sprite:sprite ~/anki/anki_data/.local/share/Anki2/addons21/ 2>/dev/null || true

# ============================================================================
# Step 9: Set up Anki MCP Server
# ============================================================================

echo ""
echo "Step 9a: Set up Anki MCP Server..."
if [ ! -d ~/anki-mcp-server ]; then
    git clone https://github.com/sebbacon/anki-mcp-server.git ~/anki-mcp-server
fi
cd ~/anki-mcp-server
npm install
npm run build

echo ""
echo "Step 9b: Install supergateway for MCP HTTP transport..."
npm install -g supergateway

echo ""
echo "Step 9c: Create MCP server startup script..."
cat > ~/anki-mcp-server/start-mcp.sh << 'EOF'
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
EOF
chmod +x ~/anki-mcp-server/start-mcp.sh

echo ""
echo "Step 9d: Create Sprite service for MCP server..."
sprite-env services create anki-mcp --cmd /home/sprite/anki-mcp-server/start-mcp.sh --needs anki 2>/dev/null || echo "Service anki-mcp may already exist"

# ============================================================================
# Step 10: Set up REST API Service
# ============================================================================

echo ""
echo "Step 10: Create Sprite service for REST API..."
sprite-env services create anki-rest --cmd /home/sprite/anki/start-rest-proxy.sh --needs anki 2>/dev/null || echo "Service anki-rest may already exist"

# ============================================================================
# Step 11: Final Restart
# ============================================================================

echo ""
echo "Step 11: Restart Anki container to load AnkiConnect..."
cd ~/anki
sudo docker compose restart

# ============================================================================
# Step 12: Create Helper Scripts
# ============================================================================

echo ""
echo "Step 12: Creating helper scripts..."

cat > ~/anki/start-anki.sh << 'EOF'
#!/bin/bash
sprite-env services start anki
EOF
chmod +x ~/anki/start-anki.sh

cat > ~/anki/stop-anki.sh << 'EOF'
#!/bin/bash
sprite-env services stop anki
EOF
chmod +x ~/anki/stop-anki.sh

cat > ~/anki/status-anki.sh << 'EOF'
#!/bin/bash
sprite-env services list
EOF
chmod +x ~/anki/status-anki.sh

# ============================================================================
# Complete
# ============================================================================

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Anki is now running and accessible on:"
echo "  - Local: http://localhost:3000"
echo "  - Via Sprite URL: (check your Sprite dashboard)"
echo ""
echo "Authentication:"
echo "  Basic Auth:"
echo "    - Username: ${ANKI_AUTH_USERNAME}"
echo "    - Password: ${ANKI_AUTH_PASSWORD}"
echo "  API Key (X-API-Key header):"
echo "    - ${ANKI_API_KEY}"
echo ""
echo "Endpoints:"
echo "  - Web UI: /"
echo "  - MCP Server: /mcp/sse, /mcp/message, /mcp/health"
echo "  - REST API: /anki-api/deckNames, /anki-api/addNote, etc."
echo "  - OpenAPI spec: /anki-api/openapi.json"
echo ""
echo "Service management:"
echo "  sprite-env services list              # List all services"
echo "  sprite-env services restart anki      # Restart Anki"
echo "  sprite-env services restart anki-mcp  # Restart MCP server"
echo "  sprite-env services restart anki-rest # Restart REST API"
echo ""
