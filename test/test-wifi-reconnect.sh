#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEST_LOG_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_equals() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: ${test_name}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: ${test_name}"
        echo "  Expected: '${expected}'"
        echo "  Actual:   '${actual}'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}PASS${NC}: ${test_name}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: ${test_name}"
        echo "  Expected to contain: '${needle}'"
        echo "  In: '${haystack}'"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "${GREEN}PASS${NC}: ${test_name}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: ${test_name}"
        echo "  Expected NOT to contain: '${needle}'"
        echo "  In: '${haystack}'"
        FAIL=$((FAIL + 1))
    fi
}

# Source the script functions without running main
# We override main-related globals
LOG_DIR="$TEST_LOG_DIR"
TARGET_SSID="SilverGate"
WIFI_DEVICE="wlan0"
CHECK_INTERVAL=0

# Source only the functions by extracting them
# We'll re-define nmcli as a mock
MOCK_NMCLI_OUTPUT=""
MOCK_NMCLI_EXIT=0
MOCK_NMCLI_CALLS=()

nmcli() {
    MOCK_NMCLI_CALLS+=("nmcli $*")
    echo "$MOCK_NMCLI_OUTPUT"
    return "$MOCK_NMCLI_EXIT"
}
export -f nmcli

# We need sleep to be a no-op in tests
sleep() { :; }

# Source the functions from the script (skip main execution)
source <(sed 's/^main "\$@"$//' "$REPO_DIR/wifi-reconnect.sh")

# Re-set variables that were overwritten by sourcing the script
LOG_DIR="$TEST_LOG_DIR"
TARGET_SSID="SilverGate"
WIFI_DEVICE="wlan0"
CHECK_INTERVAL=0

echo "==============================="
echo "WiFi Reconnect Watchdog Tests"
echo "==============================="
echo ""

# --- Test: detect_wifi_device ---
echo "--- Device Detection ---"

MOCK_NMCLI_OUTPUT="wlan0:wifi"
detect_wifi_device 2>/dev/null
assert_equals "detect_wifi_device finds wifi device" "wlan0" "$WIFI_DEVICE"

MOCK_NMCLI_OUTPUT=""
WIFI_DEVICE=""
detect_wifi_device 2>/dev/null && result="ok" || result="fail"
assert_equals "detect_wifi_device fails when no device" "fail" "$result"
WIFI_DEVICE="wlan0"

echo ""

# --- Test: is_wifi_radio_on ---
echo "--- WiFi Radio Check ---"

MOCK_NMCLI_OUTPUT="enabled"
is_wifi_radio_on && result="on" || result="off"
assert_equals "is_wifi_radio_on returns true when enabled" "on" "$result"

MOCK_NMCLI_OUTPUT="disabled"
is_wifi_radio_on && result="on" || result="off"
assert_equals "is_wifi_radio_on returns false when disabled" "off" "$result"

echo ""

# --- Test: get_current_ssid ---
echo "--- SSID Detection ---"

MOCK_NMCLI_OUTPUT="yes:SilverGate"
result="$(get_current_ssid)"
assert_equals "get_current_ssid returns connected SSID" "SilverGate" "$result"

MOCK_NMCLI_OUTPUT="no:AleXNet"
result="$(get_current_ssid)"
assert_equals "get_current_ssid returns empty when not active" "" "$result"

echo ""

# --- Test: is_connected_to_target ---
echo "--- Connection Check ---"

MOCK_NMCLI_OUTPUT="yes:SilverGate"
is_connected_to_target && result="yes" || result="no"
assert_equals "connected to target returns true" "yes" "$result"

MOCK_NMCLI_OUTPUT="yes:AleXNet"
is_connected_to_target && result="yes" || result="no"
assert_equals "connected to wrong SSID returns false" "no" "$result"

MOCK_NMCLI_OUTPUT=""
is_connected_to_target && result="yes" || result="no"
assert_equals "disconnected returns false" "no" "$result"

echo ""

# --- Test: get_device_state ---
echo "--- Device State ---"

MOCK_NMCLI_OUTPUT="wlan0:connected"
result="$(get_device_state)"
assert_equals "get_device_state returns connected" "connected" "$result"

MOCK_NMCLI_OUTPUT="wlan0:unavailable"
result="$(get_device_state)"
assert_equals "get_device_state returns unavailable" "unavailable" "$result"

echo ""

# --- Test: Logging ---
echo "--- Logging ---"

log "test message"
log_content="$(cat "${TEST_LOG_DIR}"/wifi-reconnect-*.log 2>/dev/null)"
assert_contains "log writes to file" "test message" "$log_content"
assert_contains "log includes timestamp" "$(date '+%Y-%m-%d')" "$log_content"

echo ""

# --- Test: enable_wifi_radio ---
echo "--- Recovery Actions ---"

MOCK_NMCLI_CALLS=()
MOCK_NMCLI_OUTPUT=""
enable_wifi_radio 2>/dev/null
assert_contains "enable_wifi_radio calls nmcli radio wifi on" "nmcli radio wifi on" "${MOCK_NMCLI_CALLS[*]}"

MOCK_NMCLI_CALLS=()
set_device_managed 2>/dev/null
assert_contains "set_device_managed calls nmcli device set" "nmcli device set wlan0 managed yes" "${MOCK_NMCLI_CALLS[*]}"

echo ""

# --- Test: attempt_reconnect escalation ---
echo "--- Reconnect Escalation ---"

# Mock: device connect succeeds, then is_connected_to_target returns true
call_count=0
nmcli() {
    ((call_count++))
    MOCK_NMCLI_CALLS+=("nmcli $*")
    case "$*" in
        "device connect"*) return 0 ;;
        *"-f active,ssid"*) echo "yes:SilverGate" ;;
        "radio wifi") echo "enabled" ;;
        *) echo "" ;;
    esac
    return 0
}

MOCK_NMCLI_CALLS=()
attempt_reconnect "$(date +%s)" 2>/dev/null && result="ok" || result="fail"
assert_equals "reconnect succeeds on device connect" "ok" "$result"
assert_contains "tries device connect first" "nmcli device connect wlan0" "${MOCK_NMCLI_CALLS[*]}"
assert_not_contains "does not escalate if first attempt works" "nmcli connection up" "${MOCK_NMCLI_CALLS[*]}"

# Mock: device connect fails, connection up succeeds
nmcli() {
    MOCK_NMCLI_CALLS+=("nmcli $*")
    case "$*" in
        "device connect"*) return 1 ;;
        "connection up"*) return 0 ;;
        *"-f active,ssid"*) echo "yes:SilverGate" ;;
        *) echo "" ;;
    esac
    return 0
}

MOCK_NMCLI_CALLS=()
attempt_reconnect "$(date +%s)" 2>/dev/null && result="ok" || result="fail"
assert_equals "reconnect falls back to connection up" "ok" "$result"
assert_contains "tries connection up" "nmcli connection up SilverGate" "${MOCK_NMCLI_CALLS[*]}"

# Mock: both fail, full reset needed
reset_called=false
nmcli() {
    MOCK_NMCLI_CALLS+=("nmcli $*")
    case "$*" in
        "device connect"*) return 1 ;;
        "connection up"*)
            if [[ "$reset_called" == "true" ]]; then
                return 0
            fi
            return 1
            ;;
        "radio wifi off") reset_called=true; return 0 ;;
        "radio wifi on") return 0 ;;
        *"-f active,ssid"*)
            if [[ "$reset_called" == "true" ]]; then
                echo "yes:SilverGate"
            fi
            ;;
        *) echo "" ;;
    esac
    return 0
}

MOCK_NMCLI_CALLS=()
attempt_reconnect "$(date +%s)" 2>/dev/null && result="ok" || result="fail"
assert_equals "reconnect escalates to full reset" "ok" "$result"
assert_contains "toggles radio off" "nmcli radio wifi off" "${MOCK_NMCLI_CALLS[*]}"
assert_contains "toggles radio on" "nmcli radio wifi on" "${MOCK_NMCLI_CALLS[*]}"

echo ""

# --- Cleanup ---
rm -rf "$TEST_LOG_DIR"

echo "==============================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "==============================="

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
