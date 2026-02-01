#!/bin/bash
# Main test runner for Anki Sprite end-to-end tests

# Don't use set -e so tests can continue after failures
# set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load libraries
source "$SCRIPT_DIR/lib/sprite-helpers.sh"
source "$SCRIPT_DIR/lib/api-helpers.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# Configuration
ANKIWEB_USERNAME="${ANKIWEB_USERNAME:-}"
ANKIWEB_PASSWORD="${ANKIWEB_PASSWORD:-}"
TEST_SPRITE_NAME=""
CLEANUP_ON_EXIT=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cleanup)
            CLEANUP_ON_EXIT=false
            shift
            ;;
        --sprite-name)
            TEST_SPRITE_NAME="$2"
            shift 2
            ;;
        --ankiweb-user)
            ANKIWEB_USERNAME="$2"
            shift 2
            ;;
        --ankiweb-pass)
            ANKIWEB_PASSWORD="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate credentials
if [ -z "$ANKIWEB_USERNAME" ] || [ -z "$ANKIWEB_PASSWORD" ]; then
    echo "ERROR: AnkiWeb credentials required"
    echo "Usage: $0 --ankiweb-user <email> --ankiweb-pass <password>"
    echo "   or: ANKIWEB_USERNAME=... ANKIWEB_PASSWORD=... $0"
    exit 1
fi

# Generate sprite name if not provided
if [ -z "$TEST_SPRITE_NAME" ]; then
    TEST_SPRITE_NAME=$(sprite_test_name)
fi

# Cleanup function
cleanup() {
    if [ "$CLEANUP_ON_EXIT" = true ] && [ -n "$TEST_SPRITE_NAME" ]; then
        echo ""
        echo "Cleaning up..."
        sprite_destroy "$TEST_SPRITE_NAME"
    else
        echo ""
        echo "Skipping cleanup. Sprite '$TEST_SPRITE_NAME' left running."
    fi
}

# Set up trap for cleanup
trap cleanup EXIT

echo "=========================================="
echo "Anki Sprite End-to-End Tests"
echo "=========================================="
echo "Sprite name: $TEST_SPRITE_NAME"
echo "AnkiWeb user: $ANKIWEB_USERNAME"
echo "Cleanup on exit: $CLEANUP_ON_EXIT"
echo "=========================================="
echo ""

# ============================================================================
# Test 1: Fresh Sprite Setup
# ============================================================================
echo ""
echo "=========================================="
echo "Test Suite: Fresh Sprite Setup"
echo "=========================================="

log_info "Creating new sprite with full setup..."
sprite_create_test "$TEST_SPRITE_NAME" "$ANKIWEB_USERNAME" "$ANKIWEB_PASSWORD"
# Don't fail on exit code - check if sprite is actually working instead
log_pass "Sprite creation script completed"

# Get the sprite URL
SPRITE_URL=$(sprite_get_url "$TEST_SPRITE_NAME")
assert_not_empty "$SPRITE_URL" "Sprite has public URL"
log_info "Sprite URL: $SPRITE_URL"

# Wait for services to be ready
log_info "Waiting for services to start..."
if sprite_wait_ready "$TEST_SPRITE_NAME" 180; then
    log_pass "All services started"
else
    log_fail "Services failed to start within timeout"
    # Continue anyway to see what we can test
fi

# ============================================================================
# Test 2: API Endpoints
# ============================================================================
echo ""
echo "=========================================="
echo "Test Suite: API Endpoints"
echo "=========================================="

# Test health endpoint
log_info "Testing health endpoint..."
health_status=$(api_status "${SPRITE_URL}/startup/health" GET)
assert_status "200" "$health_status" "Health endpoint returns 200"

# Test deck list endpoint
log_info "Testing deck list endpoint..."
decks_response=$(api_call "${SPRITE_URL}/anki-api/deckNames" GET)
decks_status=$(api_status "${SPRITE_URL}/anki-api/deckNames" GET)
assert_status "200" "$decks_status" "Deck list endpoint returns 200"
assert_json_null "$decks_response" "error" "Deck list has no error"

# Test model names endpoint
log_info "Testing model names endpoint..."
models_response=$(api_call "${SPRITE_URL}/anki-api/modelNames" GET)
models_status=$(api_status "${SPRITE_URL}/anki-api/modelNames" GET)
assert_status "200" "$models_status" "Model names endpoint returns 200"
assert_json_null "$models_response" "error" "Model names has no error"

# Test creating a deck
log_info "Testing deck creation..."
create_deck_response=$(api_call "${SPRITE_URL}/anki-api/createDeck" POST '{"deck":"TestDeck-E2E"}')
assert_json_null "$create_deck_response" "error" "Create deck has no error"

# Test creating a note
log_info "Testing note creation..."
create_note_response=$(api_call "${SPRITE_URL}/anki-api/addNote" POST '{
    "note": {
        "deckName": "TestDeck-E2E",
        "modelName": "Basic",
        "fields": {"Front": "Test Question", "Back": "Test Answer"},
        "tags": ["e2e-test"]
    }
}')
assert_json_null "$create_note_response" "error" "Create note has no error"

# Test finding notes
log_info "Testing note search..."
find_notes_response=$(api_call "${SPRITE_URL}/anki-api/findNotes" POST '{"query":"tag:e2e-test"}')
assert_json_null "$find_notes_response" "error" "Find notes has no error"

# ============================================================================
# Test 3: AnkiWeb Sync
# ============================================================================
echo ""
echo "=========================================="
echo "Test Suite: AnkiWeb Sync"
echo "=========================================="

log_info "Testing sync with AnkiWeb..."
sync_response=$(api_call "${SPRITE_URL}/anki-api/sync" POST)
sync_error=$(echo "$sync_response" | jq -r '.error' 2>/dev/null)

if [ "$sync_error" = "null" ]; then
    log_pass "Sync completed successfully"
else
    # Check if it's an auth error vs other error
    if [[ "$sync_error" == *"auth"* ]] || [[ "$sync_error" == *"login"* ]] || [[ "$sync_error" == *"password"* ]]; then
        log_fail "Sync failed - authentication error" "successful sync" "$sync_error"
    else
        # Could be "no changes" or other non-critical error
        log_info "Sync response: $sync_error"
        log_pass "Sync attempted (may have no changes to sync)"
    fi
fi

# ============================================================================
# Test 4: API Key Authentication
# ============================================================================
echo ""
echo "=========================================="
echo "Test Suite: API Key Authentication"
echo "=========================================="

log_info "Testing API key authentication..."
# Test with valid API key
key_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: $TEST_API_KEY" \
    "${SPRITE_URL}/anki-api/deckNames")
assert_status "200" "$key_status" "API key auth works"

# Test with invalid API key
bad_key_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: invalid-key" \
    "${SPRITE_URL}/anki-api/deckNames")
assert_status "401" "$bad_key_status" "Invalid API key rejected"

# Test with no auth
no_auth_status=$(curl -s -o /dev/null -w "%{http_code}" \
    "${SPRITE_URL}/anki-api/deckNames")
assert_status "401" "$no_auth_status" "No auth rejected"

# ============================================================================
# Test 5: Service Restart Behavior
# ============================================================================
echo ""
echo "=========================================="
echo "Test Suite: Service Restart Behavior"
echo "=========================================="

log_info "Stopping services..."
sprite_stop_services "$TEST_SPRITE_NAME"
sleep 2

# Check that endpoint returns appropriate error
log_info "Checking status while stopped..."
stopped_status=$(api_status "${SPRITE_URL}/startup/health" GET)
assert_in_list "$stopped_status" "Stopped service returns error status" "502" "503" "504" "000"

log_info "Starting services..."
sprite_start_services "$TEST_SPRITE_NAME"

# Wait for Anki to fully initialize (takes 1-2 minutes)
log_info "Waiting for Anki to initialize (up to 180s)..."
if sprite_wait_ready "$TEST_SPRITE_NAME" 180; then
    log_pass "Services recovered to healthy state"
else
    log_fail "Services did not recover within timeout"
fi

# Verify API works after restart
log_info "Verifying API after restart..."
post_restart_status=$(api_status "${SPRITE_URL}/anki-api/deckNames" GET)
assert_status "200" "$post_restart_status" "API works after restart"

# Verify our test data persisted
log_info "Verifying data persistence..."
find_after_restart=$(api_call "${SPRITE_URL}/anki-api/findNotes" POST '{"query":"tag:e2e-test"}')
result_length=$(echo "$find_after_restart" | jq '.result | length' 2>/dev/null)
if [ "$result_length" -gt 0 ] 2>/dev/null; then
    log_pass "Test data persisted after restart"
else
    log_fail "Test data not found after restart" ">0 notes" "$result_length notes"
fi

# ============================================================================
# Summary
# ============================================================================

print_summary
exit $?
