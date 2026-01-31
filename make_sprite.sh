#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for .env file
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    echo "ERROR: .env file not found!"
    echo "Please copy .env.example to .env and configure your settings:"
    echo "  cp .env.example .env"
    exit 1
fi

# Load environment variables
set -a
source "${SCRIPT_DIR}/.env"
set +a

# Validate sprite name
if [ -z "$SPRITE_NAME" ]; then
    echo "ERROR: SPRITE_NAME not set in .env"
    exit 1
fi

echo "=== Sprite Setup: ${SPRITE_NAME} ==="
echo ""

# 1. Create a new sprite
sprite create "${SPRITE_NAME}" -skip-console

# Wait for sprite to be ready
echo "Waiting for sprite to be ready..."
sleep 2

# 2. Build file upload arguments for all scripts
FILE_ARGS="-file ${SCRIPT_DIR}/.env:/home/sprite/.env"
FILE_ARGS="$FILE_ARGS -file ${SCRIPT_DIR}/setup-anki.sh:/home/sprite/setup-anki.sh"

# Add each file from scripts directory individually
for file in "${SCRIPT_DIR}/scripts/"*; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        FILE_ARGS="$FILE_ARGS -file ${file}:/home/sprite/scripts/${filename}"
    fi
done

# Upload files and run setup
eval sprite exec -s "${SPRITE_NAME}" $FILE_ARGS -- bash /home/sprite/setup-anki.sh

# 3. Make URL publicly accessible (with basic auth protection)
sprite url update -s "${SPRITE_NAME}" --auth public

# 4. Get the URL
sprite url -s "${SPRITE_NAME}"