#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Integration tests require root. Run with sudo.${NC}"
    exit 1
fi

echo "======================================="
echo "WiFi Reconnect Integration Tests"
echo "======================================="
echo ""

# --- Test: Install ---
echo "--- Install ---"

"${REPO_DIR}/install.sh" 2>/dev/null
assert_equals "install.sh exits 0" "0" "$?"

assert_equals "script installed to /usr/local/bin" "true" \
    "$([[ -f /usr/local/bin/wifi-reconnect.sh ]] && echo true || echo false)"

assert_equals "service file installed" "true" \
    "$([[ -f /etc/systemd/system/wifi-reconnect.service ]] && echo true || echo false)"

echo ""

# --- Test: Service running ---
echo "--- Service Status ---"

service_active="$(systemctl is-active wifi-reconnect.service 2>/dev/null || true)"
assert_equals "service is active" "active" "$service_active"

service_enabled="$(systemctl is-enabled wifi-reconnect.service 2>/dev/null || true)"
assert_equals "service is enabled" "enabled" "$service_enabled"

echo ""

# --- Test: Service restart ---
echo "--- Service Restart ---"

systemctl restart wifi-reconnect.service
sleep 2
service_active="$(systemctl is-active wifi-reconnect.service 2>/dev/null || true)"
assert_equals "service active after restart" "active" "$service_active"

echo ""

# --- Test: Log file created ---
echo "--- Logging ---"

sleep 3
log_exists="$([[ -f /var/log/wifi-reconnect/wifi-reconnect-$(date '+%Y-%m-%d').log ]] && echo true || echo false)"
assert_equals "log file created" "true" "$log_exists"

if [[ "$log_exists" == "true" ]]; then
    log_content="$(cat /var/log/wifi-reconnect/wifi-reconnect-$(date '+%Y-%m-%d').log)"
    has_startup="$([[ "$log_content" == *"Starting WiFi reconnect watchdog"* ]] && echo true || echo false)"
    assert_equals "log contains startup message" "true" "$has_startup"
fi

echo ""

# --- Test: Uninstall ---
echo "--- Uninstall ---"

echo "n" | "${REPO_DIR}/uninstall.sh" 2>/dev/null
assert_equals "uninstall.sh exits 0" "0" "$?"

service_active="$(systemctl is-active wifi-reconnect.service 2>/dev/null || true)"
assert_equals "service stopped after uninstall" "inactive" "$service_active"

assert_equals "script removed" "false" \
    "$([[ -f /usr/local/bin/wifi-reconnect.sh ]] && echo true || echo false)"

assert_equals "service file removed" "false" \
    "$([[ -f /etc/systemd/system/wifi-reconnect.service ]] && echo true || echo false)"

echo ""
echo "======================================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "======================================="

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
