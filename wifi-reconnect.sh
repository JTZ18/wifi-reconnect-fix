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
    WIFI_DEVICE="$(nmcli -t -f DEVICE,TYPE device status | grep ':wifi$' | head -1 | cut -d: -f1 || true)"
    if [[ -z "$WIFI_DEVICE" ]]; then
        log "ERROR: No WiFi device found"
        return 1
    fi
    log "Detected WiFi device: ${WIFI_DEVICE}"
}

get_current_ssid() {
    nmcli -t -f active,ssid dev wifi list ifname "$WIFI_DEVICE" 2>/dev/null | grep '^yes:' | cut -d: -f2 || true
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
    nmcli -t -f DEVICE,STATE device status | grep "^${WIFI_DEVICE}:" | cut -d: -f2 || true
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
