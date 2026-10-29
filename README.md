# NitroSense for macOS (Acer Nitro 5 AN515-52)

A native macOS take on Acer **NitroSense** for Hackintosh laptops: fan control (Auto, Max, Custom, Curve), CoolBoost, power plan, USB power-off charging, and live thermal/power monitoring from a menu bar app that looks like the Windows original.

> [!IMPORTANT]
> **Adapted for the Acer Nitro 5 AN515-52 (8th Gen Intel Coffee Lake) running macOS Sonoma 14.0+**, tested on **macOS Sonoma 14.7** with OpenCore.
>
> Based on [ptnzzn/NitroSense-macOS](https://github.com/ptnzzn/NitroSense-macOS) (originally built for the AN515-57 on macOS 26), ported to the **AN515-52** using its native `DSDT` / `SSDT-9` ACPI tables and Embedded Controller (EC) register mappings from [nbfc-linux](https://github.com/nbfc-linux/nbfc-linux).
>
> Want to adapt this project to another Acer Nitro 5 model (such as `AN515-51`, `AN515-53`, `AN515-54`, `AN515-55`, `AN515-58`)? Read the **[Porting Guide (PORTING.md)](PORTING.md)**.

![Main window](docs/images/main.png)

## Features

- **Fan Control**: **Auto**, **Max**, **Custom** (`0–100 %` separate CPU / GPU duty) and a temperature **Curve** with an editor. By default on the AN515-52 (which shares heatpipes between CPU and GPU), the curve drives both fans.
- **6-Second Temperature Filter & Failsafe**: Uses a 6-second moving-average filter (ported from `nbfc-linux`'s `TemperatureFilter`) so brief 1-second Coffee Lake Turbo Boost PECI spikes do not cause false fan blasts. Both fans go to max at **90 °C** (configurable) when sustained, until temperatures cool down 10 °C. Fans return to Auto whenever the daemon stops.
- **Hardware CoolBoost™ (`0x10`)**: Direct EC control of Acer CoolBoost (`0x10`: `0x01` on, `0x00` off), automatically disabled when switching to Manual/Curve duty so the EC does not override custom speeds.
- **Power Plan**: Quiet / Balance / Extreme (with automatic fallback to CoolBoost control on models whose `WMBH` firmware table does not implement opcode `0x16`).
- **USB Power-Off Charging (`0x08`)**: Toggle charging via the powered-off USB port (`0x0F` on / `0x1F` off).
- **Monitoring**: CPU / GPU (or system heatsink fallback when dGPU is disabled via `-wegnoegpu`) temperature, CPU load and CPU package power (W) with 5-minute graphs and a hover readout; whole-machine draw while on battery.
- **NitroSense Key**: Maps the dedicated NitroSense key (PS/2 `e0 75`) to `F20` via `VoodooPS2Keyboard` so pressing it opens or closes the app window.
- **Menu Bar & Background Agent**: Live readout of `CPU · GPU` temperature with quick controls. Starts in the background at login.
- **OpenCore Kext Injection (SIP Compatible)**: Injects `NitroEC.kext` and `SSDT-NITRO.aml` directly into OpenCore (`EFI/OC/Kexts` and `EFI/OC/ACPI`), working out of the box even with SIP fully enabled (`csr-active-config = 00000000`).
- `nitroctl` command-line tool for status, EC hex dumps, and full control from the terminal.

| Fan Curve | Menu bar | Settings |
| --- | --- | --- |
| ![Fan curve](docs/images/curve.png) | ![Menu bar](docs/images/menu.png) | ![Settings](docs/images/settings.png) |

![Monitoring hover](docs/images/monitoring-hover.png)

## How it works

```
NitroSense.app ─┐                      ┌─ EC RAM (0xFC7E0800 on AN515-52, read / whitelisted writes)
nitroctl ───────┼─ /var/run/nitrod.sock ─ nitrod (root) ─ NitroEC.kext ─ SSDT-NITRO ─┤
                │    (JSON, admin group)                                               └─ WMI WMBH / WMBE (firmware)
                └─ (nitroctl can also talk to the kext directly with sudo)
```

| Part | What it does |
| --- | --- |
| `ACPI/SSDT-NITRO.dsl` | Adds `\_SB.NTRO` (`_HID NTRO0001`, Darwin only) under `\_SB.PCI0` with methods to read/write EC RAM at `0xFC7E0800` and call firmware WMI methods `WMBH` / `WMBE`. Also gives `\_SB.PCI0.LPCB.PS2K` an `RMCF` mapping the NitroSense key (`e0 75`) to `F20`. |
| `Kext/` NitroEC.kext | Matches `NTRO0001` and exposes a user client: read byte, 256-byte dump, and **whitelisted** writes / WMI calls (root only). Puts fans back to Auto and restores CoolBoost when unloaded. |
| `Daemon/` nitrod | Root LaunchDaemon. Keeps `config.json`, re-applies settings at start / wake, filters temperatures over a 6 s window, runs the fan curve / failsafe / mode watchdog every 2 s, reads CPU power from `powermetrics`, and serves clients over `/var/run/nitrod.sock`. |
| `App/` NitroSense.app | SwiftUI app styled after NitroSense 3. Talks only to `nitrod`, needs no root. |
| `CLI/` nitroctl | Status, EC dumps, and every control from the terminal. |

### AN515-52 EC Map Used (Offsets into EC RAM at `0xFC7E0800`)

Verified against the AN515-52 `DSDT.aml` (`OperationRegion ECMM`), `SSDT-9` (`WMBH` / `GGSI`), and `nbfc-linux` (`Acer Nitro AN515-51.json` / `AN515-54.json`):

| Function | Offset | Values |
| --- | --- | --- |
| AC status (`CDPR`) | `0x00` | bit 0 (`1` = AC plugged) |
| Keyboard 30 s timeout | `0x06` | `1E` on / `00` off |
| USB power-off charging | `0x08` | `0F` on / `1F` off |
| CoolBoost™ | `0x10` | `01` on / `00` off |
| CPU / GPU fan RPM (`C1FR` / `G1FR`) | `0x13` / `0x15` | 16-bit little-endian (`0–6122` RPM) |
| GPU / CPU fan mode | `0x21` / `0x22` | `10/20/30` (GPU) and `04/08/0C` (CPU) = Auto / Max / Manual |
| System temperature (`S1TV`) | `0x2A` | °C |
| CPU / GPU manual duty | `0x37` / `0x3A` | `0–100 %` |
| AC adapter flag (`ADPT`) | `0xA3` | bit 7 (`0x80` = AC plugged) |
| CPU temperature (`CTMP`) | `0xB0` | °C |
| Socket / System temperature (`SKTB`) | `0xB3` | °C |
| dGPU temperature (`SKTC` / `EST1`) | `0xB4` / `0xB6` | °C (`0` when dGPU is disabled via `-wegnoegpu`, falls back to `0xB3`/`0x2A`) |
| Battery status (`BST0`) | `0xC1` | `00` idle, `01` discharging, `02` charging |

## Requirements

- **Acer Nitro 5 AN515-52** Hackintosh booting with **OpenCore**, with the EFI partition on `disk0s1` (override with `EFI_DISK=diskXsY`).
- **macOS Sonoma 14.0 or newer** (tested on macOS Sonoma 14.7).
- Xcode Command Line Tools (`clang`, `swiftc`) if building from source.

## Build & Install

```bash
# 1. Build all components (SSDT-NITRO.aml, NitroEC.kext, nitroctl, nitrod, NitroSense.app)
make

# 2. Install into OpenCore EFI + LaunchDaemon + /Applications
./Scripts/install-all.sh
```

What `./Scripts/install-all.sh` does:
1. Mounts your OpenCore EFI partition, backs up `EFI/OC/config.plist`, copies `SSDT-NITRO.aml` to `EFI/OC/ACPI` (and enables it in `ACPI -> Add`), and copies `NitroEC.kext` to `EFI/OC/Kexts` (and enables it in `Kernel -> Add`, plus `/Library/Extensions`).
2. Installs and starts the `com.nitrosense.nitrod` root LaunchDaemon in `/Library/Application Support/NitroSense`.
3. Copies `NitroSense.app` to `/Applications` and launches it.

After running `./Scripts/install-all.sh` for the first time, **reboot** so OpenCore injects `SSDT-NITRO.aml` and `NitroEC.kext`.

### Verifying after reboot

```bash
ioreg -c NitroEC -w0
./build/nitroctl status
./build/nitroctl daemon status
```

### Updating Daemon / App without rebooting

If `SSDT-NITRO.aml` and `NitroEC.kext` are already loaded and you only modified `Core/`, `Daemon/`, `CLI/`, or `App/`:

```bash
make cli daemon app
sudo ./Scripts/install-daemon.sh
./Scripts/install-app.sh
```

## Command line (`nitroctl`)

```bash
nitroctl status                                  # sensors, fans, modes, CoolBoost, power
nitroctl dump                                    # 256-byte hex dump of EC RAM
nitroctl watch 1                                 # live status every 1s
sudo nitroctl fan auto | max | manual 60         # [cpu|gpu|all] (0-100%)
sudo nitroctl coolboost on | off                 # toggle hardware CoolBoost (0x10)
sudo nitroctl usb-charge on | off                # toggle USB power-off charging (0x08)
nitroctl daemon status                           # query nitrod over /var/run/nitrod.sock
nitroctl daemon set '{"fan":{"mode":"curve"}}'   # persist & apply config via nitrod
```

Writes made directly with `sudo nitroctl` are temporary; use `nitroctl daemon set` or `NitroSense.app` to persist settings across reboots and sleep/wake cycles.

## Uninstall

```bash
sudo ./Scripts/uninstall-daemon.sh   # stops nitrod, returns fans to Auto
sudo ./Scripts/uninstall.sh          # removes kext and SSDT entry from OpenCore & /Library/Extensions
```

## Porting to other Acer Nitro 5 models

See **[PORTING.md](PORTING.md)** for a complete technical guide on how to inspect your `DSDT.aml` / `SSDT` tables and `nbfc-linux` profiles to adapt this project to other Acer Nitro 5 laptops.

## Safety

- This software writes directly to your laptop's Embedded Controller (EC) memory window. `NitroEC.kext` enforces a strict whitelist of registers and values verified for the AN515-52 / AN515-57.
- On a different laptop model, the EC MMIO base address (`0xFC7E0800` vs `0xFE0B0800`) and register offsets may differ. **Always follow [PORTING.md](PORTING.md) to verify your DSDT before installing on another model.**
- Provided as is, without warranty.

## Credits

- Original macOS architecture, kext, daemon, CLI and SwiftUI interface by [ptnzzn/NitroSense-macOS](https://github.com/ptnzzn/NitroSense-macOS)
- [nbfc-linux](https://github.com/nbfc-linux/nbfc-linux) (`Acer Nitro AN515-51.json` / `AN515-54.json` EC register maps and moving-average temperature filter design)
- [0x7375646F/Linuwu-Sense](https://github.com/0x7375646F/Linuwu-Sense)
- [MehmetCanWT/OpeNitro](https://github.com/MehmetCanWT/OpeNitro)

NitroSense and Acer are trademarks of Acer Inc. This project is not affiliated with Acer.

## License

[GPL-3.0](LICENSE)
