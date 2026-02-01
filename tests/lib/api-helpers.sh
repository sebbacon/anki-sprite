#!/bin/bash
# API testing helper functions

# Make an authenticated API call
# Usage: api_call <url> <method> [data]
api_call() {
    local url="$1"
    local method="${2:-GET}"
    local data="$3"

    local curl_args="-s -X $method"
    curl_args="$curl_args -u testuser:testpass123"
    curl_args="$curl_args -H 'Content-Type: application/json'"

    if [ -n "$data" ]; then
        curl_args="$curl_args -d '$data'"
    fi

    eval curl $curl_args "$url"
}

# Make an API call and return HTTP status code
# Usage: api_status <url> <method> [data]
api_status() {
    local url="$1"
    local method="${2:-GET}"
    local data="$3"

    local curl_args="-s -o /dev/null -w '%{http_code}' -X $method"
    curl_args="$curl_args -u testuser:testpass123"
    curl_args="$curl_args -H 'Content-Type: application/json'"

    if [ -n "$data" ]; then
        curl_args="$curl_args -d '$data'"
    fi

    eval curl $curl_args "$url"
}

# Make an API call with API key auth
# Usage: api_call_key <url> <api_key> <method> [data]
api_call_key() {
    local url="$1"
    local api_key="$2"
    local method="${3:-GET}"
    local data="$4"

    local curl_args="-s -X $method"
    curl_args="$curl_args -H 'X-API-Key: $api_key'"
    curl_args="$curl_args -H 'Content-Type: application/json'"

    if [ -n "$data" ]; then
        curl_args="$curl_args -d '$data'"
    fi

    eval curl $curl_args "$url"
}

# Call AnkiConnect directly on the sprite
# Usage: anki_connect <sprite_name> <action> [params_json]
anki_connect() {
    local name="$1"
    local action="$2"
    local params="${3:-{}}"

    local payload="{\"action\":\"$action\",\"version\":6,\"params\":$params}"

    sprite exec -s "$name" -- curl -s localhost:8765 -d "$payload"
}

# Poll an endpoint until we get expected status
# Usage: poll_until_status <url> <expected_status> [timeout] [interval]
poll_until_status() {
    local url="$1"
    local expected="$2"
    local timeout="${3:-60}"
    local interval="${4:-2}"

    local start_time=$(date +%s)
    while true; do
        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -ge $timeout ]; then
            echo "TIMEOUT"
            return 1
        fi

        local status=$(api_status "$url" GET)
        if [ "$status" = "$expected" ]; then
            echo "$status"
            return 0
        fi

        sleep $interval
    done
}

# Poll and collect status codes during startup
# Usage: collect_startup_statuses <url> <duration> [interval]
collect_startup_statuses() {
    local url="$1"
    local duration="$2"
    local interval="${3:-1}"

    local start_time=$(date +%s)
    local statuses=""

    while true; do
        local elapsed=$(($(date +%s) - start_time))
        if [ $elapsed -ge $duration ]; then
            break
        fi

        local status=$(curl -s -o /dev/null -w "%{http_code}" -u "testuser:testpass123" "$url" 2>/dev/null)
        statuses="$statuses $status"
        sleep $interval
    done

    echo $statuses
}
