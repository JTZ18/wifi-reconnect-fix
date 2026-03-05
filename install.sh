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
