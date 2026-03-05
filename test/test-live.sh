#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
TIMEOUT=60

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Live tests require root. Run with sudo.${NC}"
    exit 1
fi

if ! systemctl is-active wifi-reconnect.service &>/dev/null; then
    echo -e "${RED}Error: wifi-reconnect service is not running. Install first.${NC}"
    exit 1
fi

WIFI_DEVICE="$(nmcli -t -f DEVICE,TYPE device status | grep ':wifi$' | head -1 | cut -d: -f1)"
TARGET_SSID="$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d: -f2)"

if [[ -z "$WIFI_DEVICE" || -z "$TARGET_SSID" ]]; then
    echo -e "${RED}Error: Cannot detect WiFi device or current SSID.${NC}"
    exit 1
fi

echo "=========================================="
echo "WiFi Reconnect Live Disruption Tests"
echo "=========================================="
echo "  Device: ${WIFI_DEVICE}"
echo "  SSID:   ${TARGET_SSID}"
echo -e "  ${YELLOW}WARNING: This will temporarily disrupt WiFi!${NC}"
echo ""

wait_for_reconnect() {
    local start="$(date +%s)"
    while true; do
        local elapsed=$(( $(date +%s) - start ))
        if [[ $elapsed -ge $TIMEOUT ]]; then
            return 1
        fi
        local current
        current="$(nmcli -t -f active,ssid dev wifi list ifname "$WIFI_DEVICE" 2>/dev/null | grep '^yes:' | cut -d: -f2 || true)"
        if [[ "$current" == "$TARGET_SSID" ]]; then
            echo "$elapsed"
            return 0
        fi
        sleep 1
    done
}

# --- Test 1: Device disconnect ---
echo "--- Test: Device Disconnect Recovery ---"
echo "Disconnecting ${WIFI_DEVICE}..."
nmcli device disconnect "$WIFI_DEVICE"
echo "Waiting for auto-reconnect (timeout: ${TIMEOUT}s)..."

if recovery_time="$(wait_for_reconnect)"; then
    echo -e "${GREEN}PASS${NC}: Reconnected after device disconnect (${recovery_time}s)"
    ((++PASS))
else
    echo -e "${RED}FAIL${NC}: Did not reconnect within ${TIMEOUT}s"
    ((++FAIL))
    # Manually recover so next test can run
    nmcli connection up "$TARGET_SSID" 2>/dev/null || true
    sleep 5
fi

echo ""
sleep 5

# --- Test 2: Radio off ---
echo "--- Test: Radio Off Recovery ---"
echo "Turning WiFi radio off..."
nmcli radio wifi off
echo "Waiting for auto-reconnect (timeout: ${TIMEOUT}s)..."

if recovery_time="$(wait_for_reconnect)"; then
    echo -e "${GREEN}PASS${NC}: Reconnected after radio off (${recovery_time}s)"
    ((++PASS))
else
    echo -e "${RED}FAIL${NC}: Did not reconnect within ${TIMEOUT}s"
    ((++FAIL))
    # Manually recover
    nmcli radio wifi on
    sleep 5
    nmcli connection up "$TARGET_SSID" 2>/dev/null || true
    sleep 5
fi

echo ""

echo "=========================================="
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "=========================================="

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
