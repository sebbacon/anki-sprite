#!/bin/bash
# noVNC Startup Script
# Provides web-based VNC access to the Anki desktop

# Wait for VNC server to be ready
echo "Waiting for VNC server on port 5901..."
for i in {1..30}; do
    if nc -z localhost 5901 2>/dev/null; then
        echo "VNC server is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: VNC server failed to start after 30 seconds"
        exit 1
    fi
    echo "Waiting for VNC server... ($i/30)"
    sleep 1
done

# Start noVNC (websockify bridges WebSocket to VNC)
# Port 6080: noVNC web interface
# Connects to localhost:5901 (VNC display :1)
exec websockify --web=/usr/share/novnc/ 6080 localhost:5901
