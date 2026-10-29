#!/bin/bash
# Install NitroSense Phase 1: SSDT-NITRO.aml + NitroEC.kext into OpenCore (EFI/OC).
# Works with SIP enabled (csr-active-config = 00000000).
# Run from the project root after `make`:  sudo ./Scripts/install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AML="$ROOT/build/SSDT-NITRO.aml"
KEXT="$ROOT/build/NitroEC.kext"
EFI_DISK="${EFI_DISK:-disk0s1}"
PB=/usr/libexec/PlistBuddy

[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }
[[ -f "$AML" && -d "$KEXT" ]] || { echo "Build first: make"; exit 1; }

# 1. Mount EFI and back up config.plist
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

# 2. Copy SSDT-NITRO.aml and register it in ACPI > Add
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

# 3. Copy NitroEC.kext into EFI/OC/Kexts and register it in Kernel > Add
rm -rf "$OC/Kexts/NitroEC.kext"
cp -R "$KEXT" "$OC/Kexts/NitroEC.kext"
if "$PB" -c "Print :Kernel:Add" "$CONFIG" | grep -q "BundlePath = NitroEC.kext"; then
    echo "NitroEC.kext already in Kernel > Add"
else
    k=$("$PB" -c "Print :Kernel:Add" "$CONFIG" | grep -c "BundlePath = ")
    "$PB" -c "Add :Kernel:Add:${k} dict" \
          -c "Add :Kernel:Add:${k}:Arch string x86_64" \
          -c "Add :Kernel:Add:${k}:BundlePath string NitroEC.kext" \
          -c "Add :Kernel:Add:${k}:Comment string NitroSense EC driver (AN515-52)" \
          -c "Add :Kernel:Add:${k}:Enabled bool true" \
          -c "Add :Kernel:Add:${k}:ExecutablePath string Contents/MacOS/NitroEC" \
          -c "Add :Kernel:Add:${k}:MaxKernel string " \
          -c "Add :Kernel:Add:${k}:MinKernel string " \
          -c "Add :Kernel:Add:${k}:PlistPath string Contents/Info.plist" "$CONFIG"
    echo "Added NitroEC.kext to Kernel > Add (index ${k})"
fi

plutil -lint "$CONFIG"
[[ $was_mounted -eq 1 ]] || diskutil unmount "$EFI_MNT" >/dev/null 2>&1 \
    || diskutil unmount force "$EFI_MNT" >/dev/null 2>&1 \
    || echo "Note: EFI still mounted at $EFI_MNT (busy); unmount it later"

cat <<EOF

Done. Reboot to load SSDT-NITRO.aml and NitroEC.kext via OpenCore.
After reboot:   ioreg -c NitroEC     then     ./build/nitroctl status
Rollback:       sudo ./Scripts/uninstall.sh
EOF
