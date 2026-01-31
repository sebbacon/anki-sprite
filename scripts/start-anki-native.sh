#!/bin/bash
# Anki Native Startup Script
# Starts TigerVNC server with Anki running inside

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
vncserver :1 \
    -geometry 1280x720 \
    -depth 24 \
    -localhost yes \
    -SecurityTypes None

# Wait for VNC to start
for i in {1..30}; do
    if [ -S /tmp/.X11-unix/X1 ]; then
        echo "VNC server started"
        break
    fi
    sleep 1
done

# Keep the service alive by tailing the VNC log
exec tail -f /home/sprite/.config/tigervnc/*.log 2>/dev/null || sleep infinity
