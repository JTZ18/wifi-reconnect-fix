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
