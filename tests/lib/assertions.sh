#!/bin/bash
# Test assertion helpers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Log a test result
log_pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

log_fail() {
    echo -e "${RED}FAIL${NC}: $1"
    if [ -n "$2" ]; then
        echo "       Expected: $2"
    fi
    if [ -n "$3" ]; then
        echo "       Got:      $3"
    fi
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

log_skip() {
    echo -e "${YELLOW}SKIP${NC}: $1"
}

log_info() {
    echo -e "INFO: $1"
}

# Assert equality
# Usage: assert_eq <expected> <actual> <test_name>
assert_eq() {
    local expected="$1"
    local actual="$2"
    local name="$3"

    if [ "$expected" = "$actual" ]; then
        log_pass "$name"
        return 0
    else
        log_fail "$name" "$expected" "$actual"
        return 1
    fi
}

# Assert not empty
# Usage: assert_not_empty <value> <test_name>
assert_not_empty() {
    local value="$1"
    local name="$2"

    if [ -n "$value" ]; then
        log_pass "$name"
        return 0
    else
        log_fail "$name" "non-empty value" "(empty)"
        return 1
    fi
}

# Assert HTTP status code
# Usage: assert_status <expected> <actual> <test_name>
assert_status() {
    local expected="$1"
    local actual="$2"
    local name="$3"

    if [ "$expected" = "$actual" ]; then
        log_pass "$name (HTTP $actual)"
        return 0
    else
        log_fail "$name" "HTTP $expected" "HTTP $actual"
        return 1
    fi
}

# Assert JSON field exists and has expected value
# Usage: assert_json_field <json> <field> <expected> <test_name>
assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local name="$4"

    local actual=$(echo "$json" | jq -r ".$field" 2>/dev/null)

    if [ "$actual" = "$expected" ]; then
        log_pass "$name"
        return 0
    else
        log_fail "$name" "$field=$expected" "$field=$actual"
        return 1
    fi
}

# Assert JSON field is null
# Usage: assert_json_null <json> <field> <test_name>
assert_json_null() {
    local json="$1"
    local field="$2"
    local name="$3"

    local actual=$(echo "$json" | jq -r ".$field" 2>/dev/null)

    if [ "$actual" = "null" ]; then
        log_pass "$name"
        return 0
    else
        log_fail "$name" "$field=null" "$field=$actual"
        return 1
    fi
}

# Assert JSON array is not empty
# Usage: assert_json_array_not_empty <json> <field> <test_name>
assert_json_array_not_empty() {
    local json="$1"
    local field="$2"
    local name="$3"

    local length=$(echo "$json" | jq -r ".$field | length" 2>/dev/null)

    if [ "$length" -gt 0 ] 2>/dev/null; then
        log_pass "$name (length=$length)"
        return 0
    else
        log_fail "$name" "non-empty array" "length=$length"
        return 1
    fi
}

# Assert string contains substring
# Usage: assert_contains <haystack> <needle> <test_name>
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local name="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        log_pass "$name"
        return 0
    else
        log_fail "$name" "string containing '$needle'" "$haystack"
        return 1
    fi
}

# Assert value is in list
# Usage: assert_in_list <value> <test_name> <item1> <item2> ...
assert_in_list() {
    local value="$1"
    local name="$2"
    shift 2

    for item in "$@"; do
        if [ "$value" = "$item" ]; then
            log_pass "$name ($value)"
            return 0
        fi
    done

    log_fail "$name" "one of: $*" "$value"
    return 1
}

# Print test summary
print_summary() {
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo "Total:  $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo "=========================================="

    if [ $TESTS_FAILED -gt 0 ]; then
        return 1
    fi
    return 0
}
