// Settings that nitrod keeps and re-applies at boot/wake, plus the socket client
// used by nitroctl (and later the app) to talk to the daemon.

import Foundation

let nitrodSocketPath = "/var/run/nitrod.sock"
let nitrodConfigDir = "/Library/Application Support/NitroSense"
let nitrodConfigPath = nitrodConfigDir + "/config.json"

struct FanCurvePoint: Codable, Equatable {
    var temp: Int     // °C
    var percent: Int  // duty 20-100
}

struct FanConfig: Codable, Equatable {
    var mode = "auto"  // auto | max | manual | curve
    var cpuPercent = 60
    var gpuPercent = 60
    // The EC keeps the GPU fan above ~4500 RPM in manual (20 % -> 4545 RPM, Auto ~4100),
    // so by default the curve drives only the CPU fan and leaves the GPU fan on Auto.
    var curveGPU = false
    // Both fans go to max at this temperature (any mode) until 10 °C below it.
    var failsafeTemp = 95
    var curve = [FanCurvePoint(temp: 50, percent: 30), FanCurvePoint(temp: 60, percent: 40),
                 FanCurvePoint(temp: 70, percent: 55), FanCurvePoint(temp: 80, percent: 75),
                 FanCurvePoint(temp: 88, percent: 100)]
}

struct LEDConfig: Codable, Equatable {
    var effect = "static"
    var speed = 5
    var brightness = 100
    var direction = 0
    var color = "FFFFFF"
    var zones = ["FF0000", "00FF00", "0000FF", "FFFFFF"]
}

struct NitroConfig: Codable, Equatable {
    var fan = FanConfig()
    var nitroMode = "default"
    var batteryLimit = false
    var usbCharge = true
    var kbTimeout = true
    var led = LEDConfig()

    static let fanModes = ["auto", "max", "manual", "curve"]

    func validate() throws {
        func check(_ ok: Bool, _ what: String) throws {
            if !ok { throw NitroECError(description: "invalid config: \(what)") }
        }
        try check(Self.fanModes.contains(fan.mode), "fan.mode must be \(Self.fanModes.joined(separator: "|"))")
        try check((20...100).contains(fan.cpuPercent) && (20...100).contains(fan.gpuPercent), "fan percent must be 20-100")
        try check((70...98).contains(fan.failsafeTemp), "fan.failsafeTemp must be 70-98")
        try check((2...8).contains(fan.curve.count), "fan.curve needs 2-8 points")
        for (i, p) in fan.curve.enumerated() {
            try check((30...100).contains(p.temp) && (20...100).contains(p.percent), "curve point \(i) out of range")
            if i > 0 {
                try check(p.temp > fan.curve[i - 1].temp && p.percent >= fan.curve[i - 1].percent,
                          "curve must rise with temperature")
            }
        }
        try check(nitroModes[nitroMode] != nil, "nitroMode must be quiet|default|extreme")
        try check(ledEffects.contains(led.effect), "led.effect must be \(ledEffects.joined(separator: "|"))")
        try check((1...9).contains(led.speed) && (0...100).contains(led.brightness) && (0...2).contains(led.direction),
                  "led speed 1-9, brightness 0-100, direction 0-2")
        try check(led.zones.count == 4, "led.zones needs 4 colours")
        for c in [led.color] + led.zones { _ = try parseRGB(c) }
    }

    // Seed for the first run: whatever the EC currently holds.
    init(fromEC ec: [UInt8]) {
        func hexRGB(_ o: Int) -> String { String(format: "%02X%02X%02X", ec[o], ec[o + 1], ec[o + 2]) }
        if let mode = nitroModes.first(where: { $0.value == ec[Reg.nitroMode] })?.key { nitroMode = mode }
        batteryLimit = ec[Reg.battery] & 0x40 != 0
        usbCharge = ec[Reg.usbCharge] != 0x1F
        kbTimeout = ec[Reg.kbTimeout] != 0x00
        let effect = Int(ec[Reg.ledEffect])
        led = LEDConfig(effect: effect < ledEffects.count ? ledEffects[effect] : "static",
                        speed: (1...9).contains(Int(ec[Reg.ledSpeed])) ? Int(ec[Reg.ledSpeed]) : 5,
                        brightness: min(Int(ec[Reg.ledBright]), 100),
                        direction: min(Int(ec[Reg.ledDir]), 2),
                        color: hexRGB(Reg.ledColor),
                        zones: (0..<4).map { hexRGB(Reg.zoneColors + $0 * 3) })
    }

    init() {}

    // Decode `patch` (a partial config as a JSON object) on top of `self`.
    // Unknown keys are rejected so typos do not silently do nothing.
    func merged(with patch: [String: Any]) throws -> NitroConfig {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        let merged = try deepMerge(base, patch, path: "")
        let data = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(NitroConfig.self, from: data)
    }
}

private func deepMerge(_ base: [String: Any], _ patch: [String: Any], path: String) throws -> [String: Any] {
    var out = base
    for (key, value) in patch {
        guard let old = base[key] else {
            throw NitroECError(description: "unknown config key '\(path)\(key)'")
        }
        if let oldDict = old as? [String: Any], let newDict = value as? [String: Any] {
            out[key] = try deepMerge(oldDict, newDict, path: path + key + ".")
        } else {
            out[key] = value
        }
    }
    return out
}

// Linear interpolation over the curve, rounded to 5 % steps to avoid fan hunting.
func curvePercent(_ curve: [FanCurvePoint], _ temp: Int) -> Int {
    guard let first = curve.first, let last = curve.last else { return 100 }
    var p: Double
    if temp <= first.temp {
        p = Double(first.percent)
    } else if temp >= last.temp {
        p = Double(last.percent)
    } else {
        let hi = curve.firstIndex { $0.temp >= temp }!
        let a = curve[hi - 1], b = curve[hi]
        p = Double(a.percent) + Double(b.percent - a.percent) * Double(temp - a.temp) / Double(b.temp - a.temp)
    }
    let stepped = Int((p / 5).rounded(.up)) * 5
    return min(max(stepped, 20), 100)
}

// One request per connection: a JSON object terminated by newline; the reply is one JSON object.
func nitrodRequest(_ request: [String: Any]) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NitroECError(description: "socket() failed") }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in nitrodSocketPath.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else {
        throw NitroECError(description: "cannot reach nitrod at \(nitrodSocketPath) (\(String(cString: strerror(errno)))); is the daemon installed?")
    }
    var payload = try JSONSerialization.data(withJSONObject: request)
    payload.append(0x0A)
    _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        reply.append(contentsOf: chunk[0..<n])
    }
    guard let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        throw NitroECError(description: "bad reply from nitrod")
    }
    return obj
}
