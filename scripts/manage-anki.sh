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
