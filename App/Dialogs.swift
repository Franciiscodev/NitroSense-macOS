// Overlay dialogs: Keyboard Lighting (as in NitroSense) and the fan curve editor.

import SwiftUI

struct DialogFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(NS.text)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .light)).foregroundStyle(Color(white: 0.75))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            content
        }
        .padding(16)
        .frame(width: 680)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.32), lineWidth: 1))
        .overlay(alignment: .top) {
            Capsule().fill(Color(white: 0.35)).frame(width: 120, height: 3).offset(y: -1)
        }
        .shadow(color: .black.opacity(0.6), radius: 20)
    }
}

// MARK: - Keyboard Lighting

let dynamicEffects = ["breathing", "wave", "zoom", "meteor", "shifting", "neon", "twinkling"]
let basicColors = ["FF0000", "FF8000", "FFFF00", "00FF00", "00C0C0", "0000FF", "FF00FF", "8000FF", "FFFFFF"]

struct LightingPanel: View {
    @Environment(NitroModel.self) private var model
    let close: () -> Void

    var body: some View {
        let led = model.config.led
        let isStatic = led.effect == "static"
        DialogFrame(title: "Keyboard  Lighting", close: close) {
            HStack(spacing: 22) {
                HexRadio(label: "Static", selected: isStatic) { setLED(["effect": "static"]) { $0.effect = "static" } }
                HexRadio(label: "Dynamic", selected: !isStatic) {
                    if isStatic {
                        let effect = UserDefaults.standard.string(forKey: "lastDynamicEffect") ?? "wave"
                        setLED(["effect": effect]) { $0.effect = effect }
                    }
                }
                Spacer()
                Image(systemName: "sun.min").foregroundStyle(NS.dim)
                RedSlider(value: Double(led.brightness), range: 0...100, step: 5) { v in
                    setLED(["brightness": Int(v)]) { $0.brightness = Int(v) }
                }
                .frame(width: 150)
                Image(systemName: "sun.max.fill").foregroundStyle(NS.text)
            }
            VStack(spacing: 12) {
                if isStatic {
                    KeyboardDrawing(colors: led.zones.map { Color(hexRGB: $0) }, brightness: led.brightness)
                        .frame(height: 210)
                    ZoneRow()
                } else {
                    DynamicControls()
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
            HStack(spacing: 10) {
                HexToggle(isOn: model.config.kbTimeout) { on in
                    model.config.kbTimeout = on
                    model.set(["kbTimeout": on], delay: 0)
                }
                Text("Backlight off after 30 seconds").font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
                Spacer()
            }
        }
    }

    private func setLED(_ patch: [String: Any], _ local: (inout LEDConfig) -> Void) {
        local(&model.config.led)
        model.set(["led": patch], delay: 0)
    }
}

struct ZoneRow: View {
    @Environment(NitroModel.self) private var model
    @AppStorage("zoneMemory") private var zoneMemory = "FF0000,00FF00,0000FF,FFFFFF"

    var body: some View {
        let zones = model.config.led.zones
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                if i > 0 { Rectangle().fill(Color(white: 0.25)).frame(width: 1, height: 50) }
                VStack(spacing: 10) {
                    Text("Zone \(i + 1)").font(.system(size: 12)).foregroundStyle(NS.dim)
                    HStack(spacing: 12) {
                        HexToggle(isOn: zones[i] != "000000") { on in
                            var memory = zoneMemory.split(separator: ",").map(String.init)
                            if memory.count != 4 { memory = ["FF0000", "00FF00", "0000FF", "FFFFFF"] }
                            if on {
                                setZone(i, memory[i] == "000000" ? "FFFFFF" : memory[i])
                            } else {
                                memory[i] = zones[i]
                                zoneMemory = memory.joined(separator: ",")
                                setZone(i, "000000")
                            }
                        }
                        ColorSwatchButton(hex: zones[i]) { setZone(i, $0) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func setZone(_ i: Int, _ hex: String) {
        model.config.led.zones[i] = hex
        model.set(["led": ["zones": model.config.led.zones]], delay: 0.3)
    }
}

// Little square swatch with a folded corner; opens the colour palette.
struct ColorSwatchButton: View {
    let hex: String
    let pick: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hexRGB: hex == "000000" ? "333333" : hex))
                .frame(width: 18, height: 18)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .padding(1).background(Color.black.opacity(0.5))
                }
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPalette(selected: hex) { pick($0) }
                .padding(10)
                .preferredColorScheme(.dark)
        }
    }
}

// Basic colours, recent colours and "More color..." (system picker).
struct ColorPalette: View {
    let selected: String
    let pick: (String) -> Void
    var horizontal = false
    @AppStorage("recentColors") private var recentRaw = ""

    var body: some View {
        let recent = recentRaw.split(separator: ",").map(String.init)
        let layout = horizontal ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        layout {
            VStack(alignment: .leading, spacing: 6) {
                Text("Basic colors").font(.system(size: 11)).foregroundStyle(NS.dim)
                swatches(basicColors)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent colors").font(.system(size: 11)).foregroundStyle(NS.dim)
                swatches(Array(recent.prefix(9)) + Array(repeating: "", count: max(0, 9 - recent.count)))
            }
            ColorPicker(selection: Binding(
                get: { Color(hexRGB: selected) },
                set: { choose($0.hexRGB) }
            ), supportsOpacity: false) {
                Text("More color...").font(.system(size: 11)).foregroundStyle(NS.text)
            }
        }
    }

    private func swatches(_ hexes: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(hexes.enumerated()), id: \.offset) { _, hex in
                Button { if !hex.isEmpty { choose(hex) } } label: {
                    Rectangle()
                        .fill(hex.isEmpty ? Color.clear : Color(hexRGB: hex))
                        .frame(width: 16, height: 16)
                        .overlay(Rectangle().stroke(hex == selected ? NS.text : Color(white: 0.45), lineWidth: hex == selected ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func choose(_ hex: String) {
        var recent = recentRaw.split(separator: ",").map(String.init).filter { $0 != hex }
        if !basicColors.contains(hex) { recent.insert(hex, at: 0) }
        recentRaw = recent.prefix(9).joined(separator: ",")
        pick(hex)
    }
}

struct DynamicControls: View {
    @Environment(NitroModel.self) private var model

    var body: some View {
        let led = model.config.led
        VStack(alignment: .leading, spacing: 14) {
            KeyboardDrawing(colors: Array(repeating: Color(hexRGB: led.color), count: 4), brightness: led.brightness,
                            badge: effectNames[led.effect])
                .frame(height: 150)
            Text("Light Effects").font(.system(size: 12)).foregroundStyle(NS.dim)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(130), alignment: .leading), count: 4), alignment: .leading, spacing: 10) {
                ForEach(dynamicEffects, id: \.self) { effect in
                    HexRadio(label: effectNames[effect] ?? effect, selected: led.effect == effect) {
                        UserDefaults.standard.set(effect, forKey: "lastDynamicEffect")
                        model.config.led.effect = effect
                        model.set(["led": ["effect": effect]], delay: 0)
                    }
                }
            }
            HStack(alignment: .top, spacing: 50) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Speed").font(.system(size: 12)).foregroundStyle(NS.dim)
                    RedSlider(value: Double(led.speed), range: 1...9, step: 1) { v in
                        model.config.led.speed = Int(v)
                        model.set(["led": ["speed": Int(v)]], delay: 0)
                    }
                    .frame(width: 160)
                    HStack {
                        Text("-"); Spacer(); Text("+")
                    }
                    .font(.system(size: 10)).foregroundStyle(NS.dim).frame(width: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Direction").font(.system(size: 12)).foregroundStyle(NS.dim)
                    HStack(spacing: 6) {
                        DirectionButton(icon: "arrow.left", selected: led.direction != 2) { setDirection(1) }
                        DirectionButton(icon: "arrow.right", selected: led.direction == 2) { setDirection(2) }
                    }
                }
            }
            ColorPalette(selected: led.color, pick: { hex in
                model.config.led.color = hex
                model.set(["led": ["color": hex]], delay: 0.3)
            }, horizontal: true)
        }
    }

    private func setDirection(_ d: Int) {
        model.config.led.direction = d
        model.set(["led": ["direction": d]], delay: 0)
    }
}

struct DirectionButton: View {
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? NS.red : NS.dim)
                .frame(width: 34, height: 24)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: selected ? 0.2 : 0.14)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? NS.red.opacity(0.7) : Color(white: 0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Keyboard drawing (15.6" layout with numpad, 4 zones left to right)

struct KeyRect {
    let x: Double, y: Double, w: Double, h: Double
}

let keyboardLayout: [KeyRect] = {
    var keys: [KeyRect] = []
    // Main block, 15 units wide. Row heights: function row 0.65, others 1.
    let rows: [(y: Double, h: Double, widths: [Double])] = [
        (0, 0.65, Array(repeating: 1, count: 15)),
        (0.8, 1, Array(repeating: 1, count: 13) + [2]),
        (1.8, 1, [1.5] + Array(repeating: 1, count: 12) + [1.5]),
        (2.8, 1, [1.75] + Array(repeating: 1, count: 11) + [2.25]),
        (3.8, 1, [2.25] + Array(repeating: 1, count: 10) + [1.75, 1]),
        (4.8, 1, [1, 1, 1, 1, 5, 1, 1, 1, 1, 1, 1]),
    ]
    for row in rows {
        var x = 0.0
        for w in row.widths {
            keys.append(KeyRect(x: x, y: row.y, w: w, h: row.h))
            x += w
        }
    }
    // Numpad, 4 units, starting at 15.3.
    let n = 15.3
    for i in 0..<4 { keys.append(KeyRect(x: n + Double(i), y: 0, w: 1, h: 0.65)) }
    for i in 0..<4 { keys.append(KeyRect(x: n + Double(i), y: 0.8, w: 1, h: 1)) }
    for row in [1.8, 2.8] { for i in 0..<3 { keys.append(KeyRect(x: n + Double(i), y: row, w: 1, h: 1)) } }
    keys.append(KeyRect(x: n + 3, y: 1.8, w: 1, h: 2))         // +
    for i in 0..<3 { keys.append(KeyRect(x: n + Double(i), y: 3.8, w: 1, h: 1)) }
    keys.append(KeyRect(x: n, y: 4.8, w: 2, h: 1))             // 0
    keys.append(KeyRect(x: n + 2, y: 4.8, w: 1, h: 1))         // .
    keys.append(KeyRect(x: n + 3, y: 3.8, w: 1, h: 2))         // Enter
    return keys
}()

func zoneIndex(_ k: KeyRect) -> Int {
    let cx = k.x + k.w / 2
    return cx >= 15.15 ? 3 : min(Int(cx / 5), 2)
}

struct KeyboardDrawing: View {
    let colors: [Color]
    let brightness: Int
    var badge: String?

    var body: some View {
        Canvas { ctx, size in
            let unitsW = 19.3, unitsH = 5.8
            let u = min(size.width / unitsW, size.height / unitsH)
            let ox = (size.width - unitsW * u) / 2, oy = (size.height - unitsH * u) / 2
            let level = 0.2 + 0.8 * Double(brightness) / 100
            for k in keyboardLayout {
                let r = CGRect(x: ox + k.x * u + u * 0.07, y: oy + k.y * u + u * 0.07,
                               width: k.w * u - u * 0.14, height: k.h * u - u * 0.14)
                let shape = Path(roundedRect: r, cornerRadius: u * 0.14)
                let color = colors[zoneIndex(k)]
                ctx.fill(shape, with: .color(Color(white: 0.05)))
                ctx.fill(shape, with: .color(color.opacity(0.07 * level)))
                ctx.stroke(shape, with: .color(color.opacity(level)), lineWidth: max(1.2, u * 0.06))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(white: 0.2)))
            }
        }
    }
}

// MARK: - Fan curve editor

struct CurvePanel: View {
    @Environment(NitroModel.self) private var model
    let close: () -> Void
    @State private var curve: [FanCurvePoint] = []
    @State private var error: String?

    var body: some View {
        let fan = model.config.fan
        DialogFrame(title: "Fan Curve", close: close) {
            Text("Used when Fan Control is set to Curve. Fan speed (%) by temperature (°C); fans go to max at \(fan.failsafeTemp) °C regardless.")
                .font(.system(size: 11)).foregroundStyle(NS.dim)
            HStack(alignment: .top, spacing: 14) {
                CurveGraph(curve: curve, cpuTemp: model.snapshot.cpuTemp, gpuTemp: fan.curveGPU ? model.snapshot.gpuTemp : nil)
                    .frame(height: 220)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(curve.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            StepField(text: "\(curve[i].temp)°", minus: { curve[i].temp = max(30, curve[i].temp - 1) },
                                      plus: { curve[i].temp = min(100, curve[i].temp + 1) })
                            StepField(text: "\(curve[i].percent)%", minus: { curve[i].percent = max(0, curve[i].percent - 5) },
                                      plus: { curve[i].percent = min(100, curve[i].percent + 5) })
                            Button { curve.remove(at: i) } label: {
                                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(curve.count > 2 ? NS.dim : NS.faint)
                                    .frame(width: 24, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(curve.count <= 2)
                        }
                    }
                    NSButton(label: "Add point", icon: "plus") {
                        let last = curve.last ?? FanCurvePoint(temp: 50, percent: 30)
                        curve.append(FanCurvePoint(temp: min(last.temp + 5, 100), percent: last.percent))
                    }
                    .disabled(curve.count >= 8)
                }
                .frame(width: 210, alignment: .leading)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(NS.red)
            }
            HStack {
                SettingRow(label: "Also drive the GPU fan", isOn: fan.curveGPU) {
                    model.config.fan.curveGPU = $0
                    model.set(["fan": ["curveGPU": $0]], delay: 0)
                }
                .frame(width: 250)
                Text("(off: GPU fan stays on Auto, quieter)").font(.system(size: 11)).foregroundStyle(NS.dim)
                Spacer()
                NSButton(label: "Revert") { curve = fan.curve }
                NSButton(label: "Save", icon: "checkmark") { save() }
            }
        }
        .onAppear { curve = fan.curve }
    }

    private func save() {
        var test = model.config
        test.fan.curve = curve
        do {
            try test.validate()
            error = nil
            model.config.fan.curve = curve
            model.set(["fan": ["curve": curve.map { ["temp": $0.temp, "percent": $0.percent] }]], delay: 0)
        } catch {
            self.error = "\(error)"
        }
    }
}

struct StepField: View {
    let text: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            StepButton(icon: "minus", action: minus)
            Text(text).frame(width: 40).monospacedDigit()
            StepButton(icon: "plus", action: plus)
        }
        .font(.system(size: 11))
        .foregroundStyle(NS.text)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.28), lineWidth: 1))
    }
}

// Whole 26×26 square is clickable (a plain button only hits the glyph's pixels otherwise).
struct StepButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(StepPressStyle())
    }
}

struct StepPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? NS.red.opacity(0.35) : Color.clear)
            .foregroundStyle(configuration.isPressed ? Color.white : NS.text)
    }
}

struct CurveGraph: View {
    let curve: [FanCurvePoint]
    let cpuTemp: Int
    let gpuTemp: Int?

    var body: some View {
        Canvas { ctx, size in
            let pad: CGFloat = 26
            let plot = CGRect(x: pad, y: 6, width: size.width - pad - 6, height: size.height - pad - 6)
            ctx.fill(Path(plot), with: .color(NS.inset))
            func pt(_ t: Int, _ p: Int) -> CGPoint {
                CGPoint(x: plot.minX + plot.width * CGFloat(t - 30) / 70, y: plot.maxY - plot.height * CGFloat(p) / 100)
            }
            for t in stride(from: 30, through: 100, by: 10) {
                let x = pt(t, 0).x
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                           with: .color(NS.red.opacity(0.12)), lineWidth: 1)
                ctx.draw(Text("\(t)°").font(.system(size: 9)).foregroundStyle(NS.dim), at: CGPoint(x: x, y: plot.maxY + 10))
            }
            for p in stride(from: 0, through: 100, by: 25) {
                let y = pt(30, p).y
                ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                           with: .color(Color(white: 0.17)), lineWidth: 1)
                ctx.draw(Text("\(p)%").font(.system(size: 9)).foregroundStyle(NS.dim), at: CGPoint(x: pad / 2, y: y))
            }
            func marker(_ t: Int, _ label: String, _ color: Color) {
                let x = pt(min(max(t, 30), 100), 0).x
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                           with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(color), at: CGPoint(x: x + 4, y: plot.minY + 8), anchor: .leading)
            }
            marker(cpuTemp, "CPU \(cpuTemp)°", NS.orange)
            if let gpuTemp { marker(gpuTemp, "GPU \(gpuTemp)°", .purple) }
            guard curve.count > 1 else { return }
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: pt(30, curve[0].percent).y))
            for p in curve { line.addLine(to: pt(p.temp, p.percent)) }
            line.addLine(to: CGPoint(x: plot.maxX, y: pt(100, curve.last!.percent).y))
            ctx.stroke(line, with: .color(NS.red), lineWidth: 2)
            for p in curve {
                let c = pt(p.temp, p.percent)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(NS.red))
            }
        }
    }
}
