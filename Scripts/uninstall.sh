#!/bin/bash
# Remove NitroSense Phase 1: kext from /Library/Extensions, SSDT entry from OpenCore.
#   sudo ./Scripts/uninstall.sh
set -euo pipefail

EFI_DISK="${EFI_DISK:-disk0s1}"
PB=/usr/libexec/PlistBuddy

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

kmutil unload -b com.nitrosense.NitroEC 2>/dev/null || true
rm -rf /Library/Extensions/NitroEC.kext
kmutil clear-staging 2>/dev/null || true
echo "Removed NitroEC.kext"

was_mounted=1
EFI_MNT="$(diskutil info "$EFI_DISK" | awk -F': *' '/Mount Point/ {print $2}')"
if [[ -z "$EFI_MNT" ]]; then
    was_mounted=0
    diskutil mount "$EFI_DISK" >/dev/null
    EFI_MNT="$(diskutil info "$EFI_DISK" | awk -F': *' '/Mount Point/ {print $2}')"
fi
OC="$EFI_MNT/EFI/OC"
CONFIG="$OC/config.plist"

cp "$CONFIG" "$CONFIG.bak-nitro-uninstall-$(date +%Y%m%d-%H%M%S)"
n=$("$PB" -c "Print :ACPI:Add" "$CONFIG" | grep -c "Path = ")
for ((i = n - 1; i >= 0; i--)); do
    if [[ "$("$PB" -c "Print :ACPI:Add:${i}:Path" "$CONFIG")" == "SSDT-NITRO.aml" ]]; then
        "$PB" -c "Delete :ACPI:Add:${i}" "$CONFIG"
        echo "Removed SSDT-NITRO.aml from ACPI > Add (index ${i})"
    fi
done
rm -f "$OC/ACPI/SSDT-NITRO.aml"
plutil -lint "$CONFIG"
[[ $was_mounted -eq 1 ]] || diskutil unmount "$EFI_MNT" >/dev/null 2>&1 \
    || diskutil unmount force "$EFI_MNT" >/dev/null 2>&1 \
    || echo "Note: EFI still mounted at $EFI_MNT (busy); unmount it later"

echo "Done. Reboot to finish."
