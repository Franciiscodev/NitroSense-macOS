// nitroctl — command-line client for NitroEC.kext
//
//   nitroctl [status]      decoded sensors, fans, modes, keyboard LED
//   nitroctl dump          hex dump of EC RAM 0x00..0xFF
//   nitroctl read <off>    one byte (hex or decimal offset)
//   nitroctl watch [sec]   status every <sec> seconds (default 1)
//
//   sudo nitroctl fan [cpu|gpu|all] auto
//   sudo nitroctl fan [cpu|gpu|all] max
//   sudo nitroctl fan [cpu|gpu|all] manual <20-100>   (percent)
//        (fan commands set PSEE first; add --wmi to set manual duty via firmware WMBH 0x10)
//   sudo nitroctl psee on|off            gaming-software flag (EC 0x03 bit4)
//   sudo nitroctl wmbh <op> [b0 b1 ...]  call firmware WMBH (whitelisted opcodes), hex bytes
//
//   sudo nitroctl mode quiet|default|extreme       firmware operating mode (WMBH 0x16 sub 0x0B)
//   sudo nitroctl battery limit on|off|status       80 % charge limit (firmware WMBE 0x15 / 0x14)
//   sudo nitroctl led init                         enable the 4-zone keyboard (done before every led command)
//   sudo nitroctl led restore                      re-send the colours/effect stored in EC (after boot)
//   sudo nitroctl led zone <1-4|all> <RRGGBB>      static colour per zone (switches to Static)
//   sudo nitroctl led effect <name> [speed 1-9] [RRGGBB] [dir 1|2]
//        name: static breathing neon wave shifting zoom meteor twinkling
//   sudo nitroctl led brightness <0-100>           keeps the current effect
//   sudo nitroctl led off
//   sudo nitroctl usb-charge on|off                USB charging while off/asleep (EC 0x08)
//   sudo nitroctl kb-timeout on|off                keyboard backlight off after 30 s idle (EC 0x06)

import Foundation
import IOKit

// MARK: - Kext connection

struct NitroECError: Error, CustomStringConvertible {
    let description: String
}

final class NitroEC {
    private var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kNitroECServiceClass))
        guard service != 0 else {
            throw NitroECError(description: "NitroEC.kext is not loaded (or SSDT-NITRO is missing). Check: ioreg -c NitroEC")
        }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else {
            throw NitroECError(description: "IOServiceOpen failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
    }

    deinit {
        IOServiceClose(connection)
    }

    func readByte(_ offset: UInt8) throws -> UInt8 {
        var input: UInt64 = UInt64(offset)
        var output: UInt64 = 0
        var outputCount: UInt32 = 1
        let kr = IOConnectCallScalarMethod(connection, UInt32(kNitroECSelReadByte.rawValue), &input, 1, &output, &outputCount)
        guard kr == KERN_SUCCESS else {
            throw NitroECError(description: "readByte(0x\(String(offset, radix: 16))) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
        return UInt8(truncatingIfNeeded: output)
    }

    @discardableResult
    func writeByte(_ offset: Int, _ value: Int) throws -> UInt8 {
        var input: [UInt64] = [UInt64(offset), UInt64(value)]
        var output: UInt64 = 0
        var outputCount: UInt32 = 1
        let kr = IOConnectCallScalarMethod(connection, UInt32(kNitroECSelWriteByte.rawValue), &input, 2, &output, &outputCount)
        switch kr {
        case KERN_SUCCESS:
            return UInt8(truncatingIfNeeded: output)
        case kIOReturnNotPrivileged:
            throw NitroECError(description: "writing needs root: run with sudo")
        case kIOReturnNotPermitted:
            throw NitroECError(description: "kext refused 0x\(String(offset, radix: 16)) = 0x\(String(value, radix: 16)) (not whitelisted)")
        default:
            throw NitroECError(description: "writeByte(0x\(String(offset, radix: 16))) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
    }

    func wmbh(_ opcode: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        try wmi(kNitroECSelWMBH, "WMBH", opcode, bytes)
    }

    func wmbe(_ method: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        try wmi(kNitroECSelWMBE, "WMBE", method, bytes)
    }

    private func wmi(_ selector: NitroECSelector, _ name: String, _ opcode: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        var input = [UInt8](repeating: 0, count: Int(kNitroECWMBHInSize))
        for (i, b) in bytes.prefix(input.count).enumerated() { input[i] = b }
        var scalar = UInt64(opcode)
        var output = [UInt8](repeating: 0, count: Int(kNitroECWMBHOutSize))
        var outSize = output.count
        let kr = IOConnectCallMethod(connection, UInt32(selector.rawValue), &scalar, 1,
                                     &input, input.count, nil, nil, &output, &outSize)
        switch kr {
        case KERN_SUCCESS:
            return Array(output.prefix(outSize))
        case kIOReturnNotPrivileged:
            throw NitroECError(description: "\(name) needs root: run with sudo")
        case kIOReturnNotPermitted:
            throw NitroECError(description: "kext refused \(name) 0x\(String(opcode, radix: 16)) (not whitelisted)")
        default:
            throw NitroECError(description: "\(name) 0x\(String(opcode, radix: 16)) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
    }

    func dump() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Int(kNitroECDumpSize))
        var size = Int(kNitroECDumpSize)
        let kr = IOConnectCallStructMethod(connection, UInt32(kNitroECSelDump.rawValue), nil, 0, &buffer, &size)
        guard kr == KERN_SUCCESS, size == Int(kNitroECDumpSize) else {
            throw NitroECError(description: "dump failed: 0x\(String(UInt32(bitPattern: kr), radix: 16)), size \(size)")
        }
        return buffer
    }
}

// MARK: - AN515-52 / AN515-57 EC map (offsets verified against DSDT.dsl + SSDT9 + nbfc-linux)

enum Reg {
    static let acStatus: Int = 0x00      // CDPR / ACST (bit 0)
    static let battery: Int = 0x03       // LMEN bit0, PSEE bit4 (gaming software present), BTHE bit6 (80 % limit)
    static let kbTimeout: Int = 0x06
    static let usbCharge: Int = 0x08
    static let coolBoost: Int = 0x10     // CoolBoost (nbfc AN515-51/52/54: 0x01 on, 0x00 off)
    static let cpuFanRPM: Int = 0x13     // C1FR, 16-bit LE
    static let gpuFanRPM: Int = 0x15     // G1FR, 16-bit LE
    static let ledEffect: Int = 0x17     // KBLE
    static let ledSpeed: Int = 0x18      // KBLS
    static let ledBright: Int = 0x19     // KBBP
    static let ledDir: Int = 0x1B        // KBED
    static let ledColor: Int = 0x1C      // KBCR, KBCG, KBCB
    static let coolBoostFlag: Int = 0x20 // BBMS bit3 in AN515-52 DSDT/SSDT9
    static let gpuFanMode: Int = 0x21
    static let cpuFanMode: Int = 0x22
    static let sysTempAlt: Int = 0x2A    // S1TV in AN515-52 DSDT/SSDT9
    static let nitroMode: Int = 0x2C     // OPMS
    static let cpuFanSpeed: Int = 0x37   // CPUF
    static let gpuFanSpeed: Int = 0x3A   // GPUF
    static let zoneColors: Int = 0x3C    // KB1R..KB4B
    static let acAdapter: Int = 0xA3     // ADPT bit7 (0x80) in AN515-52 DSDT
    static let cpuTemp: Int = 0xB0       // CTMP
    static let sysTemp: Int = 0xB3       // SKTB
    static let gpuTempAlt: Int = 0xB4    // SKTC in AN515-52 DSDT/SSDT9
    static let gpuTemp: Int = 0xB6       // EST1
    static let batteryStatus: Int = 0xC1 // BST0
}

func isACPlugged(_ ec: [UInt8]) -> Bool {
    (ec[Reg.acAdapter] & 0x80 != 0) || (ec[Reg.acStatus] & 0x01 != 0)
}

func isCoolBoostOn(_ ec: [UInt8]) -> Bool {
    ec[Reg.coolBoost] != 0
}

func readGPUTemp(_ ec: [UInt8]) -> UInt8 {
    if ec[Reg.gpuTemp] != 0 { return ec[Reg.gpuTemp] }
    if ec[Reg.gpuTempAlt] != 0 { return ec[Reg.gpuTempAlt] }
    return readSysTemp(ec)
}

func readSysTemp(_ ec: [UInt8]) -> UInt8 {
    ec[Reg.sysTemp] != 0 ? ec[Reg.sysTemp] : ec[Reg.sysTempAlt]
}

func hex(_ v: UInt8) -> String { String(format: "0x%02X", v) }

func fanMode(_ v: UInt8, cpu: Bool) -> String {
    switch (cpu, v) {
    case (_, 0x00): return "Auto (EC default, never set)"
    case (true, 0x04), (false, 0x10): return "Auto"
    case (true, 0x08), (false, 0x20): return "Max"
    case (true, 0x0C), (false, 0x30): return "Manual"
    default: return "? \(hex(v))"
    }
}

func nitroMode(_ v: UInt8) -> String {
    switch v {
    case 0x00: return "Quiet"
    case 0x01: return "Default"
    case 0x04: return "Extreme"
    default: return "? \(hex(v))"
    }
}

func ledEffect(_ v: UInt8) -> String {
    switch v {
    case 0x00: return "Static"
    case 0x01: return "Breathing"
    case 0x02: return "Neon"
    case 0x03: return "Wave"
    case 0x04: return "Shifting"
    case 0x05: return "Zoom"
    case 0x06: return "Meteor"
    case 0x07: return "Twinkling"
    default: return "? \(hex(v))"
    }
}

func batteryStatus(_ v: UInt8) -> String {
    switch v {
    case 0x00: return "Idle"
    case 0x01: return "Discharging"
    case 0x02: return "Charging"
    default: return "? \(hex(v))"
    }
}

func rgb(_ ec: [UInt8], _ at: Int) -> String {
    String(format: "#%02X%02X%02X", ec[at], ec[at + 1], ec[at + 2])
}

func printStatus(_ ec: [UInt8]) {
    let u16 = { (at: Int) in Int(ec[at]) | Int(ec[at + 1]) << 8 }
    let gpuT = readGPUTemp(ec)
    let sysT = readSysTemp(ec)

    print("""
    Temperatures   CPU \(ec[Reg.cpuTemp]) °C   GPU \(gpuT) °C   SYS \(sysT) °C
    CPU fan        \(u16(Reg.cpuFanRPM)) RPM   mode \(fanMode(ec[Reg.cpuFanMode], cpu: true))   manual \(ec[Reg.cpuFanSpeed])%
    GPU fan        \(u16(Reg.gpuFanRPM)) RPM   mode \(fanMode(ec[Reg.gpuFanMode], cpu: false))   manual \(ec[Reg.gpuFanSpeed])%
    CoolBoost      \(isCoolBoostOn(ec) ? "on" : "off") (0x10 = \(hex(ec[Reg.coolBoost])))
    PSEE flag      \(ec[Reg.battery] & 0x10 != 0 ? "on" : "off")
    Power          AC \(isACPlugged(ec) ? "plugged" : "unplugged")   battery \(batteryStatus(ec[Reg.batteryStatus]))
    USB off-charge \(ec[Reg.usbCharge] == 0x0F ? "on" : ec[Reg.usbCharge] == 0x1F ? "off" : "? \(hex(ec[Reg.usbCharge]))")
    KB timeout 30s \(ec[Reg.kbTimeout] == 0x1E ? "on" : ec[Reg.kbTimeout] == 0x00 ? "off" : "? \(hex(ec[Reg.kbTimeout]))")
    """)
}

func printDump(_ ec: [UInt8]) {
    print("     " + (0..<16).map { String(format: "%02X", $0) }.joined(separator: " "))
    for row in 0..<16 {
        let bytes = ec[row * 16 ..< row * 16 + 16].map { String(format: "%02X", $0) }.joined(separator: " ")
        print(String(format: "%02X:  ", row * 16) + bytes)
    }
}

func parseOffset(_ s: String) -> UInt8? {
    s.lowercased().hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s)
}

// MARK: - Fan control

enum FanUnit: CaseIterable {
    case cpu, gpu

    var modeReg: Int { self == .cpu ? Reg.cpuFanMode : Reg.gpuFanMode }
    var speedReg: Int { self == .cpu ? Reg.cpuFanSpeed : Reg.gpuFanSpeed }
    var auto: Int { self == .cpu ? 0x04 : 0x10 }
    var max: Int { self == .cpu ? 0x08 : 0x20 }
    var manual: Int { self == .cpu ? 0x0C : 0x30 }
    var wmbhGroup: UInt8 { self == .cpu ? 0x01 : 0x04 }
}

func setPSEE(_ ec: NitroEC, _ on: Bool) throws {
    // AN515-52 does not use PSEE (0x03 bit 4 is reserved in DSDT ECMM; nbfc-linux only uses 0x10, 0x21, 0x22, 0x37, 0x3A).
}

// CoolBoost (EC 0x10: 0x01 on, 0x00 off — from nbfc-linux AN515-51/52/54 configs).
func setCoolBoost(_ ec: NitroEC, _ on: Bool) throws {
    try ec.writeByte(Reg.coolBoost, on ? 0x01 : 0x00)
}

let safeTempLimit: UInt8 = 90

// Same order as OpeNitro / nbfc: disable CoolBoost for manual control, set PSEE,
// then write duty first and mode second.
func setFan(_ ec: NitroEC, _ units: [FanUnit], mode: String, percent: Int?, viaWMI: Bool) throws {
    if mode == "manual" {
        guard let percent, (0...100).contains(percent) else {
            throw NitroECError(description: "manual speed must be 0-100 (%)")
        }
        let status = try ec.dump()
        let hottest = max(status[Reg.cpuTemp], readGPUTemp(status))
        if hottest >= safeTempLimit && percent < 100 {
            throw NitroECError(description: "refusing manual \(percent)% at \(hottest) °C (limit \(safeTempLimit) °C); use 'max'")
        }
    }

    try setPSEE(ec, true)
    if mode == "manual" {
        _ = try? setCoolBoost(ec, false)
    }
    for unit in units {
        switch mode {
        case "auto":
            try ec.writeByte(unit.modeReg, unit.auto)
        case "max":
            try ec.writeByte(unit.modeReg, unit.max)
        case "manual":
            if viaWMI {
                let result = try ec.wmbh(0x10, [unit.wmbhGroup, UInt8(percent!)])
                guard result.first == 0 else {
                    throw NitroECError(description: "firmware WMBH 0x10 returned status \(result.first ?? 0xFF)")
                }
            } else {
                try ec.writeByte(unit.speedReg, percent!)
            }
            try ec.writeByte(unit.modeReg, unit.manual)
        default:
            throw NitroECError(description: "fan mode must be auto, max or manual")
        }
    }
}

// MARK: - Operating mode (OPMS 0x2C, set through firmware WMBH 0x16 sub 0x0B)

let nitroModes: [String: UInt8] = ["quiet": 0x00, "default": 0x01, "extreme": 0x04]

// The firmware nudges \ODV0 relative to its current value for Quiet (-1) and
// Extreme (+1) and resets it to \ODV1 for Default, so always pass through Default
// first to keep repeated calls from drifting.
func setNitroMode(_ ec: NitroEC, _ name: String) throws {
    guard let value = nitroModes[name] else {
        throw NitroECError(description: "mode must be quiet, default or extreme")
    }
    // AN515-57 uses WMBH 0x16; AN515-52 SSDT9 only implements WMBH 0x01..0x13.
    if let res = try? ec.wmbh(0x16, [0x0B, 0x01]), res.first == 0 {
        if value != 0x01 {
            _ = try? ec.wmbh(0x16, [0x0B, value])
        }
    } else {
        // Fallback for AN515-52: toggle CoolBoost for Quiet vs Extreme.
        if name == "quiet" {
            try? setCoolBoost(ec, false)
        } else if name == "extreme" {
            try? setCoolBoost(ec, true)
        }
    }
}

// MARK: - Simple EC toggles (values whitelisted in the kext)

// USB charging while the laptop is off/asleep: EC 0x08, 0x0F on / 0x1F off.
func setUSBCharge(_ ec: NitroEC, _ on: Bool) throws {
    try ec.writeByte(Reg.usbCharge, on ? 0x0F : 0x1F)
}

// Keyboard backlight turns off after 30 s idle: EC 0x06, 0x1E on / 0x00 off.
func setKBTimeout(_ ec: NitroEC, _ on: Bool) throws {
    try ec.writeByte(Reg.kbTimeout, on ? 0x1E : 0x00)
}

// MARK: - Battery charge limit (firmware battery-health WMI, layout from Linuwu-Sense)

// Returns uFunctionStatus[0] (1 = 80 % limit on) from GetBatteryHealthControlStatus.
func batteryLimitStatus(_ ec: NitroEC) throws -> (on: Bool, raw: [UInt8]) {
    let raw = try ec.wmbe(0x14, [0x01, 0x01])
    guard raw.count >= 4 else {
        throw NitroECError(description: "unexpected battery-health reply: \(raw.map { hex($0) })")
    }
    return (raw[3] == 1, raw)
}

func setBatteryLimit(_ ec: NitroEC, _ on: Bool) throws {
    let reply = try ec.wmbe(0x15, [0x01, 0x01, on ? 1 : 0])
    guard reply.first == 0 else {
        throw NitroECError(description: "firmware rejected battery limit (\(reply.map { hex($0) }.joined(separator: " ")))")
    }
}

// MARK: - Keyboard LED (firmware WMBH 0x06 zone colour, 0x14 effect)

let ledEffects = ["static", "breathing", "neon", "wave", "shifting", "zoom", "meteor", "twinkling"]

struct LEDState {
    var effect: UInt8
    var speed: UInt8
    var brightness: UInt8
    var direction: UInt8
    var color: (UInt8, UInt8, UInt8)

    init(effect: UInt8, speed: UInt8, brightness: UInt8, direction: UInt8, color: (UInt8, UInt8, UInt8)) {
        self.effect = effect
        self.speed = speed
        self.brightness = brightness
        self.direction = direction
        self.color = color
    }

    init(_ ec: [UInt8]) {
        effect = ec[Reg.ledEffect]
        speed = ec[Reg.ledSpeed]
        brightness = ec[Reg.ledBright]
        direction = ec[Reg.ledDir]
        color = (ec[Reg.ledColor], ec[Reg.ledColor + 1], ec[Reg.ledColor + 2])
    }
}

func parseRGB(_ s: String) throws -> (UInt8, UInt8, UInt8) {
    let hexString = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard hexString.count == 6, let v = UInt32(hexString, radix: 16) else {
        throw NitroECError(description: "colour must be RRGGBB, got '\(s)'")
    }
    return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
}

func checkWMBH(_ result: [UInt8], _ what: String) throws {
    guard result.first == 0 else {
        throw NitroECError(description: "firmware rejected \(what) (status \(result.first.map { hex($0) } ?? "none"))")
    }
}

// AN515-57 only lights its 4-zone keyboard after GetGamingSysInfo (0x05) and
// SetGamingLED(keyboard, all zones) (0x02), as the JafarAkhondali Linux module does.
func initLED(_ ec: NitroEC) throws {
    _ = try ec.wmbh(0x05, [0x00])
    try checkWMBH(try ec.wmbh(0x02, [0x08, 0, 0, 0, 0, 0x0F]), "keyboard zone enable")
}

func applyLED(_ ec: NitroEC, _ led: LEDState) throws {
    // Some Nitro ECs reject speed 0, even for Static (see negihimanshu015/NitroSense-Linux).
    let speed = led.speed == 0 ? 5 : led.speed
    // 16-byte layout from facer_rgb.py: byte 3 = 8 for Wave, byte 9 = 1.
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = led.effect
    bytes[1] = speed
    bytes[2] = led.brightness
    bytes[3] = led.effect == 3 ? 8 : 0
    bytes[4] = led.direction
    (bytes[5], bytes[6], bytes[7]) = led.color
    bytes[9] = 1
    try checkWMBH(try ec.wmbh(0x14, bytes), "LED effect")
}

