#!/bin/bash
# Copy build/NitroSense.app to /Applications and start it. No sudo needed for admin users.
# The first launch from /Applications registers it as a login item (toggle in the gear menu).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$ROOT/build/NitroSense.app" ]] || { echo "build/NitroSense.app missing: run make app"; exit 1; }
# Quit the running copy by bundle id (the login-agent copy has a relative argv[0]).
pid="$(lsappinfo info -only pid -app com.nitrosense.app 2>/dev/null | sed -n 's/.*=//p')"
[[ -n "$pid" && "$pid" != "[ NULL ]" ]] && kill "$pid" 2>/dev/null
sleep 1
rm -rf /Applications/NitroSense.app
ditto "$ROOT/build/NitroSense.app" /Applications/NitroSense.app
open /Applications/NitroSense.app
echo "installed /Applications/NitroSense.app"
