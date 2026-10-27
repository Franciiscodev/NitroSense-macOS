#!/bin/bash
# One-shot install from a release folder (or after `make`):
#   1. SSDT-NITRO into OpenCore + NitroEC.kext into /Library/Extensions   (sudo)
#   2. nitrod LaunchDaemon                                                   (sudo)
#   3. NitroSense.app into /Applications (starts at login, in the menu bar)
# Then approve the kext in System Settings > Privacy & Security if asked, and reboot.
#   ./Scripts/install-all.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
sudo "$HERE/install.sh"
sudo "$HERE/install-daemon.sh" || echo "nitrod will connect after the reboot (it waits for the kext)"
"$HERE/install-app.sh"
echo
echo "All installed. Reboot now (and approve the kext if macOS asks)."
