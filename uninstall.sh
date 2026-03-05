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
rm -f /etc/default/wifi-reconnect
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
