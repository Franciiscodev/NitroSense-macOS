#!/bin/bash
# Stop and remove nitrod (fans go back to Auto). Keeps config.json.
set -uo pipefail
LABEL="com.nitrosense.nitrod"
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
launchctl bootout "system/$LABEL" 2>/dev/null
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/Application Support/NitroSense/nitrod" "/var/run/nitrod.sock"
echo "nitrod removed (config kept in /Library/Application Support/NitroSense)"
