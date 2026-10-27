#!/bin/bash
# Install NitroSense Phase 1: SSDT-NITRO into OpenCore + NitroEC.kext into /Library/Extensions.
# Run from the project root after `make`:  sudo ./Scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AML="$ROOT/build/SSDT-NITRO.aml"
KEXT="$ROOT/build/NitroEC.kext"
EFI_DISK="${EFI_DISK:-disk0s1}"
PB=/usr/libexec/PlistBuddy

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
[[ -f "$AML" && -d "$KEXT" ]] || { echo "Build first: make"; exit 1; }

# 1. EFI: copy SSDT and register it in config.plist (backup first)
was_mounted=1
EFI_MNT="$(diskutil info "$EFI_DISK" | awk -F': *' '/Mount Point/ {print $2}')"
if [[ -z "$EFI_MNT" ]]; then
    was_mounted=0
    diskutil mount "$EFI_DISK" >/dev/null
    EFI_MNT="$(diskutil info "$EFI_DISK" | awk -F': *' '/Mount Point/ {print $2}')"
fi
OC="$EFI_MNT/EFI/OC"
CONFIG="$OC/config.plist"
[[ -f "$CONFIG" ]] || { echo "No $CONFIG"; exit 1; }

BACKUP="$CONFIG.bak-nitro-$(date +%Y%m%d-%H%M%S)"
cp "$CONFIG" "$BACKUP"
echo "Backed up config.plist -> $BACKUP"

cp "$AML" "$OC/ACPI/SSDT-NITRO.aml"
if "$PB" -c "Print :ACPI:Add" "$CONFIG" | grep -q "Path = SSDT-NITRO.aml"; then
    echo "SSDT-NITRO.aml already in ACPI > Add"
else
    n=$("$PB" -c "Print :ACPI:Add" "$CONFIG" | grep -c "Path = ")
    "$PB" -c "Add :ACPI:Add:${n} dict" \
          -c "Add :ACPI:Add:${n}:Comment string NitroSense EC access (NitroEC.kext)" \
          -c "Add :ACPI:Add:${n}:Enabled bool true" \
          -c "Add :ACPI:Add:${n}:Path string SSDT-NITRO.aml" "$CONFIG"
    echo "Added SSDT-NITRO.aml to ACPI > Add (index ${n})"
fi
plutil -lint "$CONFIG"
[[ $was_mounted -eq 1 ]] || diskutil unmount "$EFI_MNT" >/dev/null 2>&1 \
    || diskutil unmount force "$EFI_MNT" >/dev/null 2>&1 \
    || echo "Note: EFI still mounted at $EFI_MNT (busy); unmount it later"

# 2. Kext: /Library/Extensions + Auxiliary KC (same way as NVRM*.kext on this machine)
rm -rf /Library/Extensions/NitroEC.kext
cp -R "$KEXT" /Library/Extensions/
chown -R root:wheel /Library/Extensions/NitroEC.kext
chmod -R 755 /Library/Extensions/NitroEC.kext
# Stages the kext for the Auxiliary KC; a new or changed kext needs approval in
# System Settings > Privacy & Security, then a reboot. (Never --update-all: that
# rebuilds the boot KC and needs a KDK.)
kmutil load -p /Library/Extensions/NitroEC.kext || true

cat <<EOF

Done. Reboot to load SSDT-NITRO (and to approve the kext if macOS asks).
After reboot:   ioreg -c NitroEC     then     ./build/nitroctl status
Rollback:       sudo ./Scripts/uninstall.sh   (or boot Safe Mode with Shift if the kext misbehaves)
EOF
