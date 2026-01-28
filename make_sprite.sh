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

# 2. Upload .env and setup script, then run the setup
sprite exec -s "${SPRITE_NAME}" \
    -file "${SCRIPT_DIR}/.env:/home/sprite/.env" \
    -file "${SCRIPT_DIR}/setup-anki.sh:/home/sprite/setup-anki.sh" \
    -- bash /home/sprite/setup-anki.sh

# 3. Make URL publicly accessible (with basic auth protection)
sprite url update -s "${SPRITE_NAME}" --auth public

# 4. Get the URL
sprite url -s "${SPRITE_NAME}"