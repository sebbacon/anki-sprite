#!/bin/bash
# Anki Native Startup Script
# Starts TigerVNC server with Anki running inside
# Waits for AnkiConnect to be available before service is considered ready

# Kill any existing VNC server on display :1
timeout 5 vncserver -kill :1 2>/dev/null || true

# Clean up any stale lock files
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# Set environment
export HOME=/home/sprite
export USER=sprite
export DISPLAY=:1
export XDG_DATA_HOME="$HOME/anki/anki_data/.local/share"
export XDG_CONFIG_HOME="$HOME/anki/anki_data/.config"
export XDG_RUNTIME_DIR="/tmp/runtime-sprite"
export LC_ALL=en_US.UTF-8
export DISABLE_QT5_COMPAT=1
export QTWEBENGINE_DISABLE_SANDBOX=1
export QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-gpu"

# Ensure directories exist
mkdir -p "$XDG_DATA_HOME/Anki2"
mkdir -p "$XDG_CONFIG_HOME"
mkdir -p "$XDG_RUNTIME_DIR"

# Start VNC server in background (not using -fg to avoid process management issues)
# Use -xstartup to ensure our custom startup script is used (not /etc/X11/Xsession)
vncserver :1 \
    -geometry 1280x720 \
    -depth 24 \
    -localhost yes \
    -SecurityTypes None \
    -xstartup ~/.vnc/xstartup

# Wait for VNC to start
for i in {1..30}; do
    if [ -S /tmp/.X11-unix/X1 ]; then
        echo "VNC server started"
        break
    fi
    sleep 1
done

# Start auto-accept sync dialog watcher in background
# This watches for the initial AnkiWeb sync dialog and auto-accepts "Download"
if [ -x ~/anki/auto-accept-sync.sh ]; then
    echo "Starting auto-accept sync watcher..."
    ~/anki/auto-accept-sync.sh &
fi

# Wait for AnkiConnect to be available (Anki takes time to fully initialize)
# This ensures dependent services don't start until Anki is ready
echo "Waiting for AnkiConnect to be available on port 8765..."
ANKICONNECT_TIMEOUT=120
ANKICONNECT_READY=false

for i in $(seq 1 $ANKICONNECT_TIMEOUT); do
    # Try to connect to AnkiConnect
    if curl -s --max-time 2 localhost:8765 -d '{"action":"version","version":6}' 2>/dev/null | grep -q '"result"'; then
        echo "AnkiConnect is ready (took ${i}s)"
        ANKICONNECT_READY=true
        break
    fi

    if [ $((i % 10)) -eq 0 ]; then
        echo "Still waiting for AnkiConnect... (${i}/${ANKICONNECT_TIMEOUT}s)"
    fi
    sleep 1
done

if [ "$ANKICONNECT_READY" = false ]; then
    echo "WARNING: AnkiConnect not available after ${ANKICONNECT_TIMEOUT}s, continuing anyway"
fi

# Keep the service alive
# Use a reliable method that doesn't depend on log files existing
while true; do
    # Check if VNC server is still running
    if [ -S /tmp/.X11-unix/X1 ]; then
        sleep 10
    else
        echo "VNC server stopped, exiting..."
        exit 1
    fi
done
