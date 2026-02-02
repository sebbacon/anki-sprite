#!/bin/bash
# Main test runner for Anki Sprite end-to-end tests

# Don't use set -e so tests can continue after failures
# set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load libraries
source "$SCRIPT_DIR/lib/sprite-helpers.sh"
source "$SCRIPT_DIR/lib/api-helpers.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# Load .env file if it exists (credentials can be overridden by env vars or CLI args)
if [ -f "$SCRIPT_DIR/../.env" ]; then
    set -a  # automatically export all variables
    source "$SCRIPT_DIR/../.env"
    set +a
fi

# Configuration (env vars override .env, CLI args override both)
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

# AnkiWeb credentials are optional - sync tests will be skipped if not provided
if [ -z "$ANKIWEB_USERNAME" ] || [ -z "$ANKIWEB_PASSWORD" ]; then
    echo "NOTE: AnkiWeb credentials not provided - sync tests will be skipped"
    echo "  To run all tests: ANKIWEB_USERNAME=... ANKIWEB_PASSWORD=... $0"
    SKIP_SYNC_TESTS=true
else
    SKIP_SYNC_TESTS=false
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
echo "AnkiWeb user: ${ANKIWEB_USERNAME:-(not set)}"
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

# Direct AnkiConnect check - verify the addon is actually running, not just the proxy
log_info "Verifying AnkiConnect is responding directly..."
ankiconnect_version=$(sprite exec -s "$TEST_SPRITE_NAME" bash -c "curl -s localhost:8765 -d '{\"action\":\"version\",\"version\":6}'" 2>/dev/null)
ankiconnect_result=$(echo "$ankiconnect_version" | jq -r '.result' 2>/dev/null)
if [ -n "$ankiconnect_result" ] && [ "$ankiconnect_result" != "null" ]; then
    log_pass "AnkiConnect addon responding (version: $ankiconnect_result)"
else
    log_fail "AnkiConnect addon not responding" "valid version" "$ankiconnect_version"
fi

# Verify User 1 profile folder was created (proves Anki loaded past first-run wizard)
log_info "Verifying Anki profile was created..."
profile_exists=$(sprite exec -s "$TEST_SPRITE_NAME" bash -c "test -d ~/anki/anki_data/.local/share/Anki2/'User 1' && echo 'yes' || echo 'no'" 2>/dev/null)
if [ "$profile_exists" = "yes" ]; then
    log_pass "User profile folder exists (Anki loaded successfully)"
else
    log_fail "User profile folder not created" "folder exists" "folder missing"
fi

# Verify AnkiWeb sync credentials were configured (if credentials were provided)
if [ "$SKIP_SYNC_TESTS" = false ]; then
    log_info "Verifying AnkiWeb credentials were configured..."
    # Check if syncKey is set in the profile database
    sync_key_check=$(sprite exec -s "$TEST_SPRITE_NAME" bash -c "python3 -c \"
import sqlite3, pickle
conn = sqlite3.connect('/home/sprite/anki/anki_data/.local/share/Anki2/prefs21.db')
cursor = conn.cursor()
cursor.execute(\\\"SELECT data FROM profiles WHERE name = 'User 1'\\\")
row = cursor.fetchone()
if row:
    profile = pickle.loads(row[0])
    sync_key = profile.get('syncKey')
    sync_user = profile.get('syncUser')
    if sync_key and len(sync_key) >= 10:
        print(f'OK: syncKey set ({len(sync_key)} chars), syncUser={sync_user}')
    elif sync_key:
        print(f'WARN: syncKey looks invalid ({len(sync_key)} chars)')
    else:
        print('FAIL: syncKey not set')
else:
    print('FAIL: profile not found')
\"" 2>/dev/null)

    if [[ "$sync_key_check" == OK:* ]]; then
        log_pass "AnkiWeb sync credentials configured in profile"
        log_info "  $sync_key_check"
    else
        log_fail "AnkiWeb sync credentials not properly configured" "syncKey set in profile" "$sync_key_check"
    fi
fi

# Test deck list endpoint
log_info "Testing deck list endpoint..."
decks_response=$(api_call "${SPRITE_URL}/anki-api/deckNames" GET)
decks_status=$(api_status "${SPRITE_URL}/anki-api/deckNames" GET)
assert_status "200" "$decks_status" "Deck list endpoint returns 200"
assert_json_null "$decks_response" "error" "Deck list has no error"

# Verify Default deck exists (proves Anki initialized correctly)
log_info "Verifying Default deck exists..."
has_default=$(echo "$decks_response" | jq -r '.result | index("Default")' 2>/dev/null)
if [ "$has_default" != "null" ]; then
    log_pass "Default deck exists (Anki fully initialized)"
else
    log_fail "Default deck not found" "Default in deck list" "$decks_response"
fi

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

if [ "$SKIP_SYNC_TESTS" = true ]; then
    log_info "Skipping sync tests - AnkiWeb credentials not provided"
else
    log_info "Testing sync with AnkiWeb..."
    sync_response=$(api_call "${SPRITE_URL}/anki-api/sync" POST)
    sync_error=$(echo "$sync_response" | jq -r '.error' 2>/dev/null)

    if [ "$sync_error" = "null" ]; then
        log_pass "Sync completed successfully"
    else
        # Any sync error should fail the test when credentials are provided
        # Common errors include: auth failures, invalid hkey, network issues
        log_fail "Sync failed" "successful sync (error: null)" "$sync_error"
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
