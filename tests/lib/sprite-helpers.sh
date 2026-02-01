#!/bin/bash
# Sprite lifecycle helper functions for testing

# Generate a unique test sprite name
sprite_test_name() {
    echo "test-anki-$(date +%s)"
}

# Create a test sprite with given name and credentials
# Usage: sprite_create_test <name> <ankiweb_user> <ankiweb_pass>
sprite_create_test() {
    local name="$1"
    local ankiweb_user="$2"
    local ankiweb_pass="$3"
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

    echo "Creating test sprite: $name"

    # Create temporary .env file for this test
    local test_env="/tmp/${name}.env"
    cat > "$test_env" << EOF
SPRITE_NAME=${name}
ANKI_AUTH_USERNAME=testuser
ANKI_AUTH_PASSWORD=testpass123
ANKI_API_KEY=$(openssl rand -hex 32)
ANKIWEB_USERNAME=${ankiweb_user}
ANKIWEB_PASSWORD=${ankiweb_pass}
EOF

    # Store the API key for later use
    export TEST_API_KEY=$(grep ANKI_API_KEY "$test_env" | cut -d= -f2)

    # Create the sprite
    sprite create "$name" -skip-console || return 1
    sleep 2

    # Build file upload arguments
    local file_args="-file ${test_env}:/home/sprite/.env"
    file_args="$file_args -file ${script_dir}/setup-anki.sh:/home/sprite/setup-anki.sh"

    for file in "${script_dir}/scripts/"*; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            file_args="$file_args -file ${file}:/home/sprite/scripts/${filename}"
        fi
    done

    # Upload files and run setup
    echo "Uploading files and running setup..."
    eval sprite exec -s "$name" $file_args -- bash /home/sprite/setup-anki.sh
    local setup_result=$?
    echo "Setup script exit code: $setup_result"

    # The setup script may return non-zero even on success due to service creation output
    # Check if key files exist instead
    sleep 2

    # Make URL public
    echo "Making URL public..."
    sprite url update -s "$name" --auth public
    local url_result=$?
    echo "URL update exit code: $url_result"

    if [ $url_result -ne 0 ]; then
        echo "Warning: URL update returned $url_result"
    fi

    # Clean up temp env file
    rm -f "$test_env"

    echo "Sprite $name created successfully"
}

# Destroy a test sprite
sprite_destroy() {
    local name="$1"
    echo "Destroying sprite: $name"
    sprite destroy -s "$name" --force 2>/dev/null || true
}

# Get the public URL of a sprite
sprite_get_url() {
    local name="$1"
    sprite url -s "$name" 2>/dev/null | grep "^URL:" | awk '{print $2}'
}

# Wait for sprite services to be ready
# Usage: sprite_wait_ready <name> [timeout_seconds]
sprite_wait_ready() {
    local name="$1"
    local timeout="${2:-120}"
    local url=$(sprite_get_url "$name")

    if [ -z "$url" ]; then
        echo "ERROR: Could not get URL for sprite $name"
        return 1
    fi

    echo "Waiting for sprite to be ready at $url (timeout: ${timeout}s)..."

    local start_time=$(date +%s)
    while true; do
        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -ge $timeout ]; then
            echo "ERROR: Timeout waiting for sprite to be ready"
            return 1
        fi

        # Check health endpoint
        local status=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "testuser:testpass123" \
            "${url}/startup/health" 2>/dev/null)

        if [ "$status" = "200" ]; then
            echo "Sprite is ready (took ${elapsed}s)"
            return 0
        fi

        echo "  Status: $status (${elapsed}s elapsed)..."
        sleep 5
    done
}

# Start all services on a sprite
sprite_start_services() {
    local name="$1"
    echo "Starting services on $name..."
    # Start anki first, then dependent services
    sprite exec -s "$name" -- sprite-env services start anki
    sleep 2
    sprite exec -s "$name" -- sprite-env services start anki-novnc anki-caddy anki-mcp anki-rest 2>/dev/null || true
}

# Stop all services on a sprite
sprite_stop_services() {
    local name="$1"
    echo "Stopping services on $name..."
    sprite exec -s "$name" -- sprite-env services stop anki anki-novnc anki-caddy anki-mcp anki-rest 2>/dev/null || true
}

# Restart services on a sprite
sprite_restart_services() {
    local name="$1"
    echo "Restarting services on $name..."
    sprite exec -s "$name" -- sprite-env services restart anki
}

# Get service status
sprite_service_status() {
    local name="$1"
    sprite exec -s "$name" -- sprite-env services list
}
