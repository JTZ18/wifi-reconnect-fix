# WiFi Reconnect Watchdog Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a bash watchdog that automatically reconnects to a target WiFi network, managed by systemd, installable on any Ubuntu machine.

**Architecture:** A single bash script polls every 10 seconds, detects WiFi failure modes via `nmcli`, and escalates through recovery steps. Systemd manages the script lifecycle. Install/uninstall scripts handle deployment.

**Tech Stack:** Bash, nmcli, systemd, bats-core (test framework)

---

### Task 1: Project scaffolding and .gitignore

**Files:**
- Create: `.gitignore`
- Create: `logs/.gitkeep`

**Step 1: Create .gitignore**

```bash
# Runtime logs
logs/*.log

# Editor
*.swp
*~
```

**Step 2: Create logs directory with .gitkeep**

The `logs/` dir needs to exist in the repo but its contents are gitignored.

**Step 3: Commit**

```bash
git add .gitignore logs/.gitkeep
git commit -m "chore: add project scaffolding and .gitignore"
```

---

### Task 2: Write the watchdog script core — device detection and connection check

**Files:**
- Create: `wifi-reconnect.sh`

**Step 1: Write wifi-reconnect.sh with device detection and main loop skeleton**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Configuration
TARGET_SSID="${1:-SilverGate}"
CHECK_INTERVAL=10
LOG_DIR="/var/log/wifi-reconnect"
WIFI_DEVICE=""

log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local log_file="${LOG_DIR}/wifi-reconnect-$(date '+%Y-%m-%d').log"
    echo "[${timestamp}] $1" | tee -a "$log_file"
}

cleanup_old_logs() {
    find "$LOG_DIR" -name "wifi-reconnect-*.log" -mtime +7 -delete 2>/dev/null || true
}

detect_wifi_device() {
    WIFI_DEVICE="$(nmcli -t -f DEVICE,TYPE device status | grep ':wifi$' | head -1 | cut -d: -f1)"
    if [[ -z "$WIFI_DEVICE" ]]; then
        log "ERROR: No WiFi device found"
        return 1
    fi
    log "Detected WiFi device: ${WIFI_DEVICE}"
}

get_current_ssid() {
    nmcli -t -f active,ssid dev wifi list ifname "$WIFI_DEVICE" 2>/dev/null | grep '^yes:' | cut -d: -f2
}

is_connected_to_target() {
    local current_ssid
    current_ssid="$(get_current_ssid)"
    [[ "$current_ssid" == "$TARGET_SSID" ]]
}

is_wifi_radio_on() {
    [[ "$(nmcli radio wifi)" == "enabled" ]]
}

get_device_state() {
    nmcli -t -f DEVICE,STATE device status | grep "^${WIFI_DEVICE}:" | cut -d: -f2
}

enable_wifi_radio() {
    log "ACTION: Enabling WiFi radio"
    nmcli radio wifi on
    sleep 5
}

set_device_managed() {
    log "ACTION: Setting ${WIFI_DEVICE} to managed"
    nmcli device set "$WIFI_DEVICE" managed yes
    sleep 5
}

attempt_reconnect() {
    local outage_start="$1"

    # Step 1: Try nmcli device connect
    log "ACTION: Attempting nmcli device connect ${WIFI_DEVICE}"
    if nmcli device connect "$WIFI_DEVICE" 2>/dev/null; then
        sleep 3
        if is_connected_to_target; then
            local duration=$(( $(date +%s) - outage_start ))
            log "SUCCESS: Reconnected to ${TARGET_SSID} via device connect (outage: ${duration}s)"
            return 0
        fi
    fi

    # Step 2: Try explicit connection up
    log "ACTION: Attempting nmcli connection up ${TARGET_SSID}"
    if nmcli connection up "$TARGET_SSID" 2>/dev/null; then
        sleep 3
        if is_connected_to_target; then
            local duration=$(( $(date +%s) - outage_start ))
            log "SUCCESS: Reconnected to ${TARGET_SSID} via connection up (outage: ${duration}s)"
            return 0
        fi
    fi

    # Step 3: Full reset — toggle WiFi off/on and retry
    log "ACTION: Full WiFi reset — toggling radio off/on"
    nmcli radio wifi off
    sleep 2
    nmcli radio wifi on
    sleep 5

    log "ACTION: Retrying nmcli connection up ${TARGET_SSID} after reset"
    if nmcli connection up "$TARGET_SSID" 2>/dev/null; then
        sleep 3
        if is_connected_to_target; then
            local duration=$(( $(date +%s) - outage_start ))
            log "SUCCESS: Reconnected to ${TARGET_SSID} after full reset (outage: ${duration}s)"
            return 0
        fi
    fi

    log "FAILED: Could not reconnect to ${TARGET_SSID} this cycle"
    return 1
}

main() {
    mkdir -p "$LOG_DIR"
    cleanup_old_logs

    log "Starting WiFi reconnect watchdog for SSID: ${TARGET_SSID}"
    detect_wifi_device || exit 1

    local outage_start=0

    while true; do
        if is_connected_to_target; then
            if [[ "$outage_start" -ne 0 ]]; then
                outage_start=0
            fi
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Not connected — begin recovery
        if [[ "$outage_start" -eq 0 ]]; then
            outage_start="$(date +%s)"
            log "DETECTED: Not connected to ${TARGET_SSID}"
        fi

        # Check WiFi radio
        if ! is_wifi_radio_on; then
            log "DETECTED: WiFi radio is off"
            enable_wifi_radio
        fi

        # Check device state
        local dev_state
        dev_state="$(get_device_state)"
        if [[ "$dev_state" == "unavailable" || "$dev_state" == "unmanaged" ]]; then
            log "DETECTED: Device ${WIFI_DEVICE} is ${dev_state}"
            set_device_managed
        fi

        # Attempt reconnect
        attempt_reconnect "$outage_start" || true

        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
```

**Step 2: Make it executable and verify syntax**

Run: `bash -n wifi-reconnect.sh`
Expected: no output (syntax OK)

**Step 3: Commit**

```bash
git add wifi-reconnect.sh
git commit -m "feat: add WiFi reconnect watchdog script"
```

---

### Task 3: Write the systemd service file

**Files:**
- Create: `wifi-reconnect.service`

**Step 1: Create the service file**

```ini
[Unit]
Description=WiFi Reconnect Watchdog
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wifi-reconnect.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**Step 2: Commit**

```bash
git add wifi-reconnect.service
git commit -m "feat: add systemd service unit file"
```

---

### Task 4: Write the install script

**Files:**
- Create: `install.sh`

**Step 1: Create install.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="wifi-reconnect"
INSTALL_PATH="/usr/local/bin/wifi-reconnect.sh"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

# Detect or accept SSID
TARGET_SSID="${1:-}"
if [[ -z "$TARGET_SSID" ]]; then
    TARGET_SSID="$(nmcli -t -f active,ssid dev wifi | grep '^yes:' | cut -d: -f2)"
    if [[ -z "$TARGET_SSID" ]]; then
        echo "Error: Not connected to WiFi. Please provide SSID as argument: sudo ./install.sh <SSID>"
        exit 1
    fi
    echo "Auto-detected SSID: ${TARGET_SSID}"
fi

echo "Installing WiFi reconnect watchdog for SSID: ${TARGET_SSID}"

# Copy script
cp "${SCRIPT_DIR}/wifi-reconnect.sh" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

# Write service file with SSID argument
sed "s|ExecStart=/usr/local/bin/wifi-reconnect.sh|ExecStart=/usr/local/bin/wifi-reconnect.sh ${TARGET_SSID}|" \
    "${SCRIPT_DIR}/wifi-reconnect.service" > "$SERVICE_PATH"

# Enable and start
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

echo ""
echo "Installation complete."
echo "  SSID:    ${TARGET_SSID}"
echo "  Script:  ${INSTALL_PATH}"
echo "  Service: ${SERVICE_PATH}"
echo "  Logs:    /var/log/wifi-reconnect/"
echo ""
systemctl status "${SERVICE_NAME}.service" --no-pager
```

**Step 2: Make executable and verify syntax**

Run: `bash -n install.sh`
Expected: no output

**Step 3: Commit**

```bash
git add install.sh
git commit -m "feat: add install script"
```

---

### Task 5: Write the uninstall script

**Files:**
- Create: `uninstall.sh`

**Step 1: Create uninstall.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="wifi-reconnect"
INSTALL_PATH="/usr/local/bin/wifi-reconnect.sh"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_DIR="/var/log/wifi-reconnect"

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)."
    exit 1
fi

echo "Uninstalling WiFi reconnect watchdog..."

# Stop and disable
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

# Remove files
rm -f "$INSTALL_PATH"
rm -f "$SERVICE_PATH"
systemctl daemon-reload

# Ask about logs
if [[ -d "$LOG_DIR" ]]; then
    read -rp "Remove log files in ${LOG_DIR}? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        echo "Logs removed."
    else
        echo "Logs kept at ${LOG_DIR}"
    fi
fi

echo "Uninstall complete."
```

**Step 2: Make executable and verify syntax**

Run: `bash -n uninstall.sh`
Expected: no output

**Step 3: Commit**

```bash
git add uninstall.sh
git commit -m "feat: add uninstall script"
```

---

### Task 6: Write unit tests (mocked nmcli)

**Files:**
- Create: `test/test-wifi-reconnect.sh`

These tests source the watchdog script's functions but override `nmcli` with mock functions. We use plain bash assertions (no external test framework needed).

**Step 1: Create test/test-wifi-reconnect.sh**

```bash
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
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: ${test_name}"
        echo "  Expected: '${expected}'"
        echo "  Actual:   '${actual}'"
        ((FAIL++))
    fi
}

assert_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}PASS${NC}: ${test_name}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: ${test_name}"
        echo "  Expected to contain: '${needle}'"
        echo "  In: '${haystack}'"
        ((FAIL++))
    fi
}

assert_not_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "${GREEN}PASS${NC}: ${test_name}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: ${test_name}"
        echo "  Expected NOT to contain: '${needle}'"
        echo "  In: '${haystack}'"
        ((FAIL++))
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
```

**Step 2: Make executable and verify syntax**

Run: `bash -n test/test-wifi-reconnect.sh`
Expected: no output

**Step 3: Run the tests (they should fail — script doesn't exist yet if running TDD, or pass if Task 2 is done)**

Run: `bash test/test-wifi-reconnect.sh`
Expected: All tests PASS (since the watchdog script exists from Task 2)

**Step 4: Commit**

```bash
git add test/test-wifi-reconnect.sh
git commit -m "test: add unit tests with mocked nmcli"
```

---

### Task 7: Write integration test script

**Files:**
- Create: `test/test-integration.sh`

**Step 1: Create test/test-integration.sh**

```bash
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
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: ${test_name}"
        echo "  Expected: '${expected}'"
        echo "  Actual:   '${actual}'"
        ((FAIL++))
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
```

**Step 2: Make executable and verify syntax**

Run: `bash -n test/test-integration.sh`
Expected: no output

**Step 3: Commit**

```bash
git add test/test-integration.sh
git commit -m "test: add integration tests for install/uninstall/service"
```

---

### Task 8: Write live disruption test

**Files:**
- Create: `test/test-live.sh`

**Step 1: Create test/test-live.sh**

```bash
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
        current="$(nmcli -t -f active,ssid dev wifi list ifname "$WIFI_DEVICE" 2>/dev/null | grep '^yes:' | cut -d: -f2)"
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
    ((PASS++))
else
    echo -e "${RED}FAIL${NC}: Did not reconnect within ${TIMEOUT}s"
    ((FAIL++))
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
    ((PASS++))
else
    echo -e "${RED}FAIL${NC}: Did not reconnect within ${TIMEOUT}s"
    ((FAIL++))
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
```

**Step 2: Make executable and verify syntax**

Run: `bash -n test/test-live.sh`
Expected: no output

**Step 3: Commit**

```bash
git add test/test-live.sh
git commit -m "test: add live WiFi disruption tests"
```

---

### Task 9: Add README

**Files:**
- Create: `README.md`

**Step 1: Create README.md**

```markdown
# WiFi Reconnect Fix

Automatically reconnects your Linux machine to a target WiFi network when it drops.

A bash watchdog script managed by systemd that polls every 10 seconds, detects all WiFi failure modes, and reconnects.

## Install

```bash
sudo ./install.sh              # Auto-detects current WiFi SSID
sudo ./install.sh MyNetwork    # Or specify SSID explicitly
```

## Uninstall

```bash
sudo ./uninstall.sh
```

## Check Status

```bash
sudo systemctl status wifi-reconnect
sudo journalctl -u wifi-reconnect -f    # Live logs
cat /var/log/wifi-reconnect/wifi-reconnect-$(date +%Y-%m-%d).log
```

## Testing

```bash
# Unit tests (no root, no WiFi disruption)
bash test/test-wifi-reconnect.sh

# Integration tests (requires sudo, installs/uninstalls service)
sudo bash test/test-integration.sh

# Live disruption tests (requires sudo, temporarily drops WiFi)
sudo bash test/test-live.sh
```

## How It Works

Every 10 seconds the watchdog checks if you're connected to the target SSID. If not, it escalates through recovery steps:

1. Enable WiFi radio (if off)
2. Set device to managed (if unavailable)
3. `nmcli device connect` (reconnect to preferred network)
4. `nmcli connection up <SSID>` (explicit reconnect)
5. Full radio toggle off/on + retry

All actions are logged to `/var/log/wifi-reconnect/` with daily rotation (7-day retention).

## Requirements

- Ubuntu/Linux with NetworkManager and nmcli
- systemd
- Root/sudo access for install
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with install, usage, and testing instructions"
```

---

### Task 10: Run all tests and push

**Step 1: Run unit tests**

Run: `bash test/test-wifi-reconnect.sh`
Expected: All PASS, exit 0

**Step 2: Run integration tests**

Run: `sudo bash test/test-integration.sh`
Expected: All PASS, exit 0

**Step 3: Run live disruption tests**

Run: `sudo bash test/test-live.sh`
Expected: All PASS (WiFi will drop briefly and recover)

**Step 4: Push everything**

```bash
git push origin main
```
