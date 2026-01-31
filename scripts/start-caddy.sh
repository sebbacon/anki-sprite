#!/bin/bash
# Caddy Reverse Proxy Startup Script
# Provides authentication and routing for all Anki services

cd /home/sprite/anki

# Wait for noVNC to be ready
echo "Waiting for noVNC on port 6080..."
for i in {1..30}; do
    if nc -z localhost 6080 2>/dev/null; then
        echo "noVNC is ready"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "WARNING: noVNC not ready after 30 seconds, starting Caddy anyway..."
        break
    fi
    echo "Waiting for noVNC... ($i/30)"
    sleep 1
done

# Run Caddy with our configuration
exec caddy run --config /home/sprite/anki/Caddyfile
