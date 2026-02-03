#!/bin/bash
# Anki Native Setup Script
# This script sets up Anki natively (without Docker) with VNC access and all supporting services
# Run with: bash setup-anki.sh
#
# Configuration files are stored in the scripts/ folder for better maintainability.
# Secrets are loaded from .env file (see .env.example for template)

set -e

echo "=== Anki Native Setup ==="
echo ""

# ============================================================================
# Configuration
# ============================================================================

ANKI_VERSION="${ANKI_VERSION:-25.02.4}"

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
# Step 1: System Setup - Install Dependencies
# ============================================================================

echo "Step 1: Update system packages and install dependencies..."
sudo apt update
sudo apt install -y \
    gettext-base \
    wget \
    zstd \
    xdg-utils \
    libxcb-xinerama0 \
    libxcb-cursor0 \
    python3-xdg \
    lame \
    mplayer \
    tigervnc-standalone-server \
    tigervnc-common \
    openbox \
    xterm \
    dbus-x11 \
    x11-xkb-utils \
    xfonts-base \
    locales \
    curl \
    git \
    libxkbcommon0 \
    libxcb-keysyms1 \
    libxcb-render-util0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libegl1 \
    libopengl0 \
    libgl1 \
    fontconfig \
    fonts-dejavu-core \
    novnc \
    websockify \
    netcat-openbsd \
    libnss3 \
    libxkbcommon-x11-0 \
    libxcb-shape0 \
    xdotool

# Ensure locale is set
sudo locale-gen en_US.UTF-8

echo ""

# ============================================================================
# Step 2: Fix home directory ownership and create working directories
# ============================================================================

echo "Step 2: Fix home directory ownership and create Anki working directory..."
# On fresh Sprites, /home/sprite may be owned by ubuntu - fix this
if [ -d /home/sprite ]; then
    sudo chown sprite:sprite /home/sprite
fi
mkdir -p ~/anki
mkdir -p ~/anki/anki_data/.local/share/Anki2
mkdir -p ~/anki/anki_data/.config/openbox
mkdir -p ~/.vnc

# ============================================================================
# Step 3: Install Anki
# ============================================================================

echo ""
echo "Step 3: Install Anki ${ANKI_VERSION}..."

if command -v anki &> /dev/null; then
    echo "Anki is already installed, checking version..."
    INSTALLED_VERSION=$(anki --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    echo "Installed version: ${INSTALLED_VERSION}"
else
    echo "Downloading Anki ${ANKI_VERSION}..."
    cd /tmp

    # Download the Anki launcher
    wget -q "https://github.com/ankitects/anki/releases/download/${ANKI_VERSION}/anki-launcher-${ANKI_VERSION}-linux.tar.zst" \
        || wget -q "https://github.com/ankitects/anki/releases/download/${ANKI_VERSION}/anki-${ANKI_VERSION}-linux-qt6.tar.zst"

    # Extract and install
    if [ -f "anki-launcher-${ANKI_VERSION}-linux.tar.zst" ]; then
        tar --use-compress-program=unzstd -xf "anki-launcher-${ANKI_VERSION}-linux.tar.zst"
        cd "anki-launcher-${ANKI_VERSION}-linux"
    else
        tar --use-compress-program=unzstd -xf "anki-${ANKI_VERSION}-linux-qt6.tar.zst"
        cd "anki-${ANKI_VERSION}-linux-qt6"
    fi

    sudo ./install.sh

    # Cleanup
    cd /tmp
    rm -rf anki-launcher-${ANKI_VERSION}-linux* anki-${ANKI_VERSION}-linux*

    echo "Anki installed successfully."
fi

cd ~/anki

# ============================================================================
# Step 4: Install Caddy
# ============================================================================

echo ""
echo "Step 4: Install Caddy..."

if command -v caddy &> /dev/null; then
    echo "Caddy is already installed, skipping..."
else
    echo "Installing Caddy..."
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    sudo apt update
    sudo apt install -y caddy
    # Stop the default caddy service - we'll manage it ourselves
    sudo systemctl stop caddy || true
    sudo systemctl disable caddy || true
    echo "Caddy installed successfully."
fi

# ============================================================================
# Step 5: Generate password hash
# ============================================================================

echo ""
echo "Step 5: Generating bcrypt hash for password..."
ANKI_AUTH_PASSWORD_HASH=$(caddy hash-password --plaintext "${ANKI_AUTH_PASSWORD}")
echo "Password hash generated successfully."

# ============================================================================
# Step 6: Configure VNC
# ============================================================================

echo ""
echo "Step 6: Configure VNC server..."

# Create VNC password (using a fixed password since auth is handled by Caddy)
# Use printf with newlines to provide password and confirmation non-interactively
printf "ankivnc\nankivnc\n" | vncpasswd > /dev/null 2>&1 || true
chmod 600 ~/.vnc/passwd 2>/dev/null || true

# Create VNC xstartup script
cat > ~/.vnc/xstartup << 'XSTARTUP'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Start dbus
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval $(dbus-launch --sh-syntax)
fi

# Set keyboard layout
setxkbmap -layout us &

# Environment for Anki
export DISABLE_QT5_COMPAT=1
export LC_ALL=en_US.UTF-8
export XDG_DATA_HOME="$HOME/anki/anki_data/.local/share"
export XDG_CONFIG_HOME="$HOME/anki/anki_data/.config"
export XDG_RUNTIME_DIR="/tmp/runtime-sprite"
export QTWEBENGINE_DISABLE_SANDBOX=1
export QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu"

mkdir -p "$XDG_RUNTIME_DIR"

# Start openbox window manager
openbox &

# Wait a moment for window manager to start
sleep 2

# Start Anki with specific profile to skip profile selector
anki -p "User 1" &

# Keep the session alive
wait
XSTARTUP
chmod +x ~/.vnc/xstartup

# Create openbox autostart (this is what actually runs when VNC starts)
# Note: Must be in ~/anki/anki_data/.config/ because XDG_CONFIG_HOME points there
cat > ~/anki/anki_data/.config/openbox/autostart << 'AUTOSTART'
# Set keyboard layout
setxkbmap -layout us &

# Environment for Anki
export DISABLE_QT5_COMPAT=1
export LC_ALL=en_US.UTF-8
export XDG_DATA_HOME="$HOME/anki/anki_data/.local/share"
export XDG_CONFIG_HOME="$HOME/anki/anki_data/.config"
export XDG_RUNTIME_DIR="/tmp/runtime-sprite"
export QTWEBENGINE_DISABLE_SANDBOX=1
export QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu"

mkdir -p "$XDG_RUNTIME_DIR"

# Wait for window manager to be ready, then start Anki with specific profile
sleep 2
anki -p "User 1" &
AUTOSTART
chmod +x ~/anki/anki_data/.config/openbox/autostart

echo "VNC configuration complete."

# ============================================================================
# Step 7: Copy Configuration Files
# ============================================================================

echo ""
echo "Step 7a: Generating Caddyfile from template..."
# Use envsubst to substitute environment variables in the template
export ANKI_AUTH_USERNAME ANKI_AUTH_PASSWORD_HASH ANKI_API_KEY
envsubst '${ANKI_AUTH_USERNAME} ${ANKI_AUTH_PASSWORD_HASH} ${ANKI_API_KEY}' \
    < "${SCRIPTS_DIR}/Caddyfile.template" \
    > ~/anki/Caddyfile

echo ""
echo "Step 7b: Copying startup loading page..."
cp "${SCRIPTS_DIR}/loading.html" ~/anki/loading.html

echo ""
echo "Step 7c: Copying MCP schema file..."
cp "${SCRIPTS_DIR}/mcp-schema.json" ~/anki/mcp-schema.json

echo ""
echo "Step 7d: Copying OpenAPI spec for REST API..."
cp "${SCRIPTS_DIR}/openapi-anki.json" ~/anki/openapi-anki.json

echo ""
echo "Step 7e: Copying REST API proxy..."
cp "${SCRIPTS_DIR}/anki-rest-proxy.js" ~/anki/anki-rest-proxy.js
chmod +x ~/anki/anki-rest-proxy.js

echo ""
echo "Step 7f: Copying startup scripts..."
cp "${SCRIPTS_DIR}/start-rest-proxy.sh" ~/anki/start-rest-proxy.sh
chmod +x ~/anki/start-rest-proxy.sh

cp "${SCRIPTS_DIR}/start-anki-native.sh" ~/anki/start-anki-native.sh
chmod +x ~/anki/start-anki-native.sh

cp "${SCRIPTS_DIR}/start-caddy.sh" ~/anki/start-caddy.sh
chmod +x ~/anki/start-caddy.sh

cp "${SCRIPTS_DIR}/start-novnc.sh" ~/anki/start-novnc.sh
chmod +x ~/anki/start-novnc.sh

# ============================================================================
# Step 8: Configure Anki Profile (required to skip first-run wizard)
# ============================================================================

echo ""
echo "Step 8: Configure Anki profile..."
# Install zstandard for AnkiWeb authentication (modern sync protocol requires zstd)
pip3 install -q zstandard 2>/dev/null || pip3 install --user -q zstandard 2>/dev/null || true
# Always run to create profile with firstRun=False (skips locale dialog)
# If ANKIWEB_USERNAME and ANKIWEB_PASSWORD are set, also configures sync credentials
python3 "${SCRIPTS_DIR}/setup-ankiweb-credentials.py"

# ============================================================================
# Step 9: Install AnkiConnect Addon
# ============================================================================

echo ""
echo "Step 9: Install AnkiConnect addon..."
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

# ============================================================================
# Step 10: Copy Helper Scripts (must be before services start)
# ============================================================================

echo ""
echo "Step 10: Copying helper scripts..."
cp "${SCRIPTS_DIR}/start-anki.sh" ~/anki/start-anki.sh
cp "${SCRIPTS_DIR}/stop-anki.sh" ~/anki/stop-anki.sh
cp "${SCRIPTS_DIR}/status-anki.sh" ~/anki/status-anki.sh
cp "${SCRIPTS_DIR}/auto-accept-sync.sh" ~/anki/auto-accept-sync.sh
chmod +x ~/anki/start-anki.sh ~/anki/stop-anki.sh ~/anki/status-anki.sh ~/anki/auto-accept-sync.sh

# ============================================================================
# Step 11: Create Sprite Services
# ============================================================================

echo ""
echo "Step 11a: Create Sprite service for Anki (VNC)..."
if sprite-env services list | grep -q '^anki\b'; then
    echo "Service anki already exists, skipping..."
else
    sprite-env services create anki --cmd /home/sprite/anki/start-anki-native.sh
fi

# Wait for AnkiConnect to be available before creating dependent services
# This ensures Anki is fully loaded and ready to accept connections
echo ""
echo "Step 11a-wait: Waiting for Anki to fully initialize (this may take 1-2 minutes)..."
ANKICONNECT_TIMEOUT=180
for i in $(seq 1 $ANKICONNECT_TIMEOUT); do
    if curl -s --max-time 2 localhost:8765 -d '{"action":"version","version":6}' 2>/dev/null | grep -q '"result"'; then
        echo "AnkiConnect is ready (took ${i}s)"
        break
    fi
    if [ $((i % 15)) -eq 0 ]; then
        echo "Still waiting for AnkiConnect... (${i}/${ANKICONNECT_TIMEOUT}s)"
    fi
    sleep 1
done

# Verify AnkiConnect is responding
if ! curl -s --max-time 2 localhost:8765 -d '{"action":"version","version":6}' 2>/dev/null | grep -q '"result"'; then
    echo "WARNING: AnkiConnect not available after ${ANKICONNECT_TIMEOUT}s"
    echo "Anki may still be initializing. Continuing with service setup..."
fi

echo ""
echo "Step 11b: Create Sprite service for noVNC web interface..."
if sprite-env services list | grep -q '^anki-novnc\b'; then
    echo "Service anki-novnc already exists, skipping..."
else
    sprite-env services create anki-novnc --cmd /home/sprite/anki/start-novnc.sh --needs anki
fi

echo ""
echo "Step 11c: Create Sprite service for Caddy reverse proxy..."
if sprite-env services list | grep -q '^anki-caddy\b'; then
    echo "Service anki-caddy already exists, skipping..."
else
    sprite-env services create anki-caddy --cmd /home/sprite/anki/start-caddy.sh --needs anki-novnc --http-port 3000
fi

# ============================================================================
# Step 12: Set up Anki MCP Server
# ============================================================================

echo ""
echo "Step 12a: Set up Anki MCP Server..."
if [ ! -d ~/anki-mcp-server ]; then
    git clone https://github.com/sebbacon/anki-mcp-server.git ~/anki-mcp-server
fi
cd ~/anki-mcp-server
npm install
npm run build

echo ""
echo "Step 12b: Install supergateway for MCP HTTP transport..."
npm install -g supergateway

echo ""
echo "Step 12c: Copying MCP server startup script..."
cp "${SCRIPTS_DIR}/start-mcp.sh" ~/anki-mcp-server/start-mcp.sh
chmod +x ~/anki-mcp-server/start-mcp.sh

echo ""
echo "Step 12d: Create Sprite service for MCP server..."
if sprite-env services list | grep -q '^anki-mcp\b'; then
    echo "Service anki-mcp already exists, skipping..."
else
    sprite-env services create anki-mcp --cmd /home/sprite/anki-mcp-server/start-mcp.sh --needs anki
fi

# ============================================================================
# Step 12: Set up REST API Service
# ============================================================================

echo ""
echo "Step 13: Create Sprite service for REST API..."
if sprite-env services list | grep -q '^anki-rest\b'; then
    echo "Service anki-rest already exists, skipping..."
else
    sprite-env services create anki-rest --cmd /home/sprite/anki/start-rest-proxy.sh --needs anki
fi

# ============================================================================
# Complete
# ============================================================================

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Anki is now configured and ready to start."
echo ""
echo "To start all services:"
echo "  sprite-env services start anki"
echo ""
echo "Once started, Anki will be accessible on:"
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
echo "  sprite-env services list               # List all services"
echo "  sprite-env services restart anki       # Restart Anki"
echo "  sprite-env services restart anki-mcp   # Restart MCP server"
echo "  sprite-env services restart anki-rest  # Restart REST API"
echo "  sprite-env services restart anki-caddy # Restart Caddy proxy"
echo ""
