#!/bin/bash
# Anki Docker Setup Script
# This script sets up the complete Anki Docker environment with Sprite services
# Run with: bash setup-anki.sh
#
# Configuration files are stored in the scripts/ folder for better maintainability.
# Secrets are loaded from .env file (see .env.example for template)

set -e

echo "=== Anki Docker Setup ==="
echo ""

# ============================================================================
# Step 0: Load Environment Variables
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

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

# Validate scripts directory exists
if [ ! -d "$SCRIPTS_DIR" ]; then
    echo "ERROR: Scripts directory not found at $SCRIPTS_DIR"
    exit 1
fi

echo "Environment variables loaded successfully."
echo ""

# ============================================================================
# Step 1: System Setup
# ============================================================================

echo "Step 1: Update system packages and install dependencies..."
sudo apt update
sudo apt install -y gettext-base

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
CURRENT_USER="$(whoami)"
if groups "$CURRENT_USER" | grep -q '\bdocker\b'; then
    echo "User $CURRENT_USER already in docker group, skipping..."
else
    sudo usermod -aG docker "$CURRENT_USER"
    echo "User $CURRENT_USER added to docker group (re-login required to take effect)"
fi

echo ""
echo "Step 4: Fix home directory ownership and create Anki working directory..."
# On fresh Sprites, /home/sprite may be owned by ubuntu - fix this
# Only fix the home directory itself, not recursively (which can hang on large directories)
if [ -d /home/sprite ]; then
    sudo chown sprite:sprite /home/sprite
fi
mkdir -p ~/anki
cd ~/anki

# ============================================================================
# Step 4a: Start Docker daemon (needed before we can use Docker)
# ============================================================================

echo ""
echo "Step 4a: Copying Docker daemon wrapper script..."
cp "${SCRIPTS_DIR}/start-dockerd.sh" ~/anki/start-dockerd.sh
chmod +x ~/anki/start-dockerd.sh

echo ""
echo "Step 4b: Create Sprite service for Docker daemon..."
if sprite-env services list | grep -q '^dockerd\b'; then
    echo "Service dockerd already exists, skipping..."
else
    sprite-env services create dockerd --cmd /home/sprite/anki/start-dockerd.sh
fi

echo ""
echo "Step 4c: Wait for Docker to be ready..."
for i in {1..30}; do
    if sudo docker ps > /dev/null 2>&1; then
        echo "Docker is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Docker daemon failed to start after 30 seconds"
        exit 1
    fi
    echo "Waiting for Docker daemon... ($i/30)"
    sleep 1
done

# ============================================================================
# Step 4d: Generate password hash from plaintext password
# ============================================================================

echo ""
echo "Step 4d: Generating bcrypt hash for password..."
# Pull caddy image first so we can use it to generate the hash
sudo docker pull caddy:alpine

# Generate bcrypt hash using caddy (escaping special characters for shell)
ANKI_AUTH_PASSWORD_HASH=$(sudo docker run --rm caddy:alpine caddy hash-password --plaintext "${ANKI_AUTH_PASSWORD}")
echo "Password hash generated successfully."

# ============================================================================
# Step 5: Copy Configuration Files
# ============================================================================

echo ""
echo "Step 5a: Copying docker-compose.yml..."
cp "${SCRIPTS_DIR}/docker-compose.yml" ~/anki/docker-compose.yml

echo ""
echo "Step 5b: Generating Caddyfile from template..."
# Use envsubst to substitute environment variables in the template
export ANKI_AUTH_USERNAME ANKI_AUTH_PASSWORD_HASH ANKI_API_KEY
envsubst '${ANKI_AUTH_USERNAME} ${ANKI_AUTH_PASSWORD_HASH} ${ANKI_API_KEY}' \
    < "${SCRIPTS_DIR}/Caddyfile.template" \
    > ~/anki/Caddyfile

echo ""
echo "Step 5c: Copying startup loading page..."
cp "${SCRIPTS_DIR}/loading.html" ~/anki/loading.html

echo ""
echo "Step 5d: Copying MCP schema file..."
cp "${SCRIPTS_DIR}/mcp-schema.json" ~/anki/mcp-schema.json

echo ""
echo "Step 5e: Copying OpenAPI spec for REST API..."
cp "${SCRIPTS_DIR}/openapi-anki.json" ~/anki/openapi-anki.json

echo ""
echo "Step 5f: Copying REST API proxy..."
cp "${SCRIPTS_DIR}/anki-rest-proxy.js" ~/anki/anki-rest-proxy.js
chmod +x ~/anki/anki-rest-proxy.js

echo ""
echo "Step 5g: Copying REST API startup script..."
cp "${SCRIPTS_DIR}/start-rest-proxy.sh" ~/anki/start-rest-proxy.sh
chmod +x ~/anki/start-rest-proxy.sh

# ============================================================================
# Step 6: Create Sprite Service Scripts
# ============================================================================

echo ""
echo "Step 6: Copying Anki management script..."
cp "${SCRIPTS_DIR}/manage-anki.sh" ~/anki/manage-anki.sh
chmod +x ~/anki/manage-anki.sh

# ============================================================================
# Step 7: Start Anki Services
# ============================================================================

echo ""
echo "Step 7a: Pull Anki Docker image..."
cd ~/anki
sudo docker compose pull

echo ""
echo "Step 7b: Create Anki data directory..."
mkdir -p ~/anki/anki_data

echo ""
echo "Step 7c: Start Anki container..."
sudo docker compose up -d

echo ""
echo "Step 7d: Create Sprite service for Anki with HTTP port..."
if sprite-env services list | grep -q '^anki\b'; then
    echo "Service anki already exists, skipping..."
else
    sprite-env services create anki --cmd /home/sprite/anki/manage-anki.sh --needs dockerd --http-port 3000
fi

# ============================================================================
# Step 8: Install AnkiConnect Addon
# ============================================================================

echo ""
echo "Step 8: Install AnkiConnect addon..."
mkdir -p ~/anki/anki_data/.local/share/Anki2/addons21/2055492159
if [ ! -d /tmp/anki-connect ]; then
    echo "Cloning AnkiConnect repository..."
    if ! git clone https://github.com/FooSoft/anki-connect.git /tmp/anki-connect; then
        echo "ERROR: Failed to clone AnkiConnect repository"
        exit 1
    fi
fi
if [ -d /tmp/anki-connect/plugin ]; then
    cp -r /tmp/anki-connect/plugin/* ~/anki/anki_data/.local/share/Anki2/addons21/2055492159/
fi
cp "${SCRIPTS_DIR}/ankiconnect-config.json" ~/anki/anki_data/.local/share/Anki2/addons21/2055492159/config.json
# Set ownership to match Docker container's PUID/PGID (1000:1000)
sudo chown -R 1000:1000 ~/anki/anki_data/

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
echo "Step 9c: Copying MCP server startup script..."
cp "${SCRIPTS_DIR}/start-mcp.sh" ~/anki-mcp-server/start-mcp.sh
chmod +x ~/anki-mcp-server/start-mcp.sh

echo ""
echo "Step 9d: Create Sprite service for MCP server..."
if sprite-env services list | grep -q '^anki-mcp\b'; then
    echo "Service anki-mcp already exists, skipping..."
else
    sprite-env services create anki-mcp --cmd /home/sprite/anki-mcp-server/start-mcp.sh --needs anki
fi

# ============================================================================
# Step 10: Set up REST API Service
# ============================================================================

echo ""
echo "Step 10: Create Sprite service for REST API..."
if sprite-env services list | grep -q '^anki-rest\b'; then
    echo "Service anki-rest already exists, skipping..."
else
    sprite-env services create anki-rest --cmd /home/sprite/anki/start-rest-proxy.sh --needs anki
fi

# ============================================================================
# Step 11: Final Restart
# ============================================================================

echo ""
echo "Step 11: Restart Anki container to load AnkiConnect..."
cd ~/anki
sudo docker compose restart

# ============================================================================
# Step 12: Copy Helper Scripts
# ============================================================================

echo ""
echo "Step 12: Copying helper scripts..."
cp "${SCRIPTS_DIR}/start-anki.sh" ~/anki/start-anki.sh
cp "${SCRIPTS_DIR}/stop-anki.sh" ~/anki/stop-anki.sh
cp "${SCRIPTS_DIR}/status-anki.sh" ~/anki/status-anki.sh
chmod +x ~/anki/start-anki.sh ~/anki/stop-anki.sh ~/anki/status-anki.sh

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
