# WiFi Reconnect Watchdog — Design

## Problem

This Linux machine occasionally drops its WiFi connection to SilverGate and never automatically recovers. The user has to physically visit the machine and manually reconnect.

## Solution

A bash watchdog script managed by a systemd service that polls every 10 seconds, detects WiFi disconnection (covering all failure modes), and automatically reconnects to the target SSID.

## Approach

**Systemd Service + Bash Watchdog** was chosen over NetworkManager dispatcher scripts or hybrid approaches because:
- Zero dependencies beyond bash and nmcli (present on all Ubuntu systems)
- Covers all failure modes including ones NM dispatcher misses (silent drops, adapter confusion)
- Simple to install, test, debug, and uninstall
- 10-second polling means worst-case recovery in ~10s

## Architecture

```
wifi-reconnect-fix/
├── wifi-reconnect.sh          # The watchdog script
├── wifi-reconnect.service     # Systemd unit file
├── install.sh                 # Installer (copy files, enable service)
├── uninstall.sh               # Clean uninstaller
├── test/
│   └── test-wifi-reconnect.sh # Automated test suite
├── logs/                      # Runtime logs (gitignored)
└── .gitignore
```

## Watchdog Logic

Every 10 seconds:

1. **Check connection**: Is the WiFi device connected to the target SSID?
   - Yes → do nothing
   - No → proceed to recovery

2. **Check WiFi radio**: Is WiFi radio enabled?
   - No → `nmcli radio wifi on`, wait 5s

3. **Check device state**: Is the WiFi device available?
   - No → `nmcli device set <dev> managed yes`, wait 5s

4. **Reconnect attempt**:
   - Try `nmcli device connect <dev>`
   - If fail → try `nmcli connection up <SSID>`
   - If fail → toggle WiFi off/on, wait 5s, retry

5. **Logging**: Every action logged with timestamp to `logs/wifi-reconnect.log`
   - Daily log rotation, keep last 7 days
   - Tracks outage duration on successful recovery

### Configuration
- WiFi device name: auto-detected at startup
- Target SSID: configurable (default: SilverGate, overridable via argument)

## Systemd Service

- Starts after NetworkManager
- `Restart=always` with 5s restart delay
- Runs as root (required for radio/device management)
- Enabled at boot via `WantedBy=multi-user.target`

## Install / Uninstall

**install.sh** (requires root/sudo):
1. Detect WiFi SSID — default to current, or accept as argument
2. Copy script to `/usr/local/bin/wifi-reconnect.sh`
3. Copy service to `/etc/systemd/system/wifi-reconnect.service`
4. `systemctl daemon-reload && systemctl enable --now wifi-reconnect.service`
5. Verify and print status

**uninstall.sh** (requires root/sudo):
1. Stop and disable service
2. Remove files from `/usr/local/bin/` and `/etc/systemd/system/`
3. `systemctl daemon-reload`
4. Optionally remove logs

## Testing Strategy

### Unit Tests (no root, no WiFi disruption)
Mock `nmcli` with fake outputs, verify the watchdog makes correct decisions:
- Connected to target → no action
- Connected to wrong network → switch to target
- WiFi disconnected → reconnect attempt
- WiFi radio off → enable radio first
- Device unavailable → set managed and retry
- Reconnect fails then succeeds → verify escalation
- Log file written correctly

### Integration Tests (requires sudo)
- Service installs and starts correctly
- Service survives restart
- Log file created and written
- WiFi device auto-detected correctly
- Connection state correctly identified

### Live Disruption Tests (requires sudo, disrupts WiFi)
- `nmcli device disconnect <dev>` → verify auto-reconnect within 30s
- `nmcli radio wifi off` → verify radio re-enabled and reconnected
- Measure and report time to recovery
