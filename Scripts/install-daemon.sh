#!/bin/bash
# Install/refresh nitrod as a root LaunchDaemon.   sudo ./Scripts/install-daemon.sh
# Keeps an existing config.json; a first run seeds it from the current EC state.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Library/Application Support/NitroSense"
LABEL="com.nitrosense.nitrod"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
[[ -x "$ROOT/build/nitrod" ]] || { echo "build/nitrod missing: run make daemon"; exit 1; }

launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p "$DEST"
install -o root -g wheel -m 755 "$ROOT/build/nitrod" "$DEST/nitrod"
install -o root -g wheel -m 755 "$ROOT/build/nitroctl" "$DEST/nitroctl"

cat >"$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DEST/nitrod</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardErrorPath</key><string>/var/log/nitrod.log</string>
</dict>
</plist>
PL
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
sleep 3
launchctl print "system/$LABEL" | grep -E "state|pid" | head -3
tail -5 /var/log/nitrod.log
