#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Sprite Setup ==="
echo ""

# Check for .env file
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    echo "ERROR: .env file not found!"
    echo "Please copy .env.example to .env and configure your secrets:"
    echo "  cp .env.example .env"
    exit 1
fi

# 1. Create a new sprite
sprite create my-anki-sprite -skip-console

# 2. Upload .env and setup script, then run the setup
sprite exec -s my-anki-sprite \
    -file "${SCRIPT_DIR}/.env:/home/sprite/.env" \
    -file "${SCRIPT_DIR}/setup-anki.sh:/home/sprite/setup-anki.sh" \
    -- bash /home/sprite/setup-anki.sh

# 3. Make URL publicly accessible (with basic auth protection)
sprite url update -s my-anki-sprite --auth public

# 4. Get the URL
sprite url -s my-anki-sprite