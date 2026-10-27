import SwiftUI

// Starts in the background (menu bar only, no Dock icon) when launched with
// --background by the login agent; any other launch, a click on the app while it
// runs (reopen), or "Open NitroSense" in the menu shows the main window. Closing the
// window goes back to background.
@main
struct NitroSenseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) weak var shared: AppDelegate?
    let model: NitroModel
    private var window: NSWindow?
    private let args = CommandLine.arguments

    override init() {
        model = NitroModel(preview: CommandLine.arguments.contains("--icon"))
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NitroSense --icon <png>: render the app icon. --snapshot <dir>: render pages to PNG.
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            let renderer = ImageRenderer(content: AppIconView())
            renderer.scale = 1
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                renderSnapshots(self.model, to: dir)
                exit(0)
            }
            return
        }
        // launchd starts the agent copy directly, so it can race an instance that is
        // already running: keep the first one.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            if !args.contains("--background") { other.activate() }
            exit(0)
        }
        LoginItem.configureOnFirstRun()
        if !args.contains("--background") {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showMainWindow() {
        if window == nil {
            let host = NSHostingController(rootView: MainView().environment(model))
            host.sizingOptions = [.preferredContentSize]
            host.safeAreaRegions = []  // no title bar inset: the header shares the row with the window buttons
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "NitroSense"
            w.isMovableByWindowBackground = false  // custom SwiftUI sliders would drag the window
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
func renderSnapshots(_ model: NitroModel, to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func variant(_ effect: String) -> NitroModel {
        let m = NitroModel(preview: true)
        m.config = model.config
        m.config.led.effect = effect
        m.snapshot = model.snapshot
        m.connected = model.connected
        return m
    }
    let busy = NitroModel(preview: true)  // 5 min of made-up samples to check the hover tooltip
    busy.config = model.config
    busy.snapshot = model.snapshot
    busy.history = (0..<150).map { i in
        let t = Double(i)
        return Sample(date: Date().addingTimeInterval(Double(i - 150) * 2), cpuTemp: 60 + Int(15 * sin(t / 12)),
                      gpuTemp: 43, cpuLoad: 30 + Int(25 * sin(t / 9)), cpuPower: 20 + 15 * sin(t / 10))
    }
    let pages: [(String, AnyView, NitroModel)] = [
        ("monitoring-hover", AnyView(MonitoringPanel().frame(width: 680, height: 300)), busy),
        ("main", AnyView(MainView()), model),
        ("lighting-static", AnyView(LightingPanel {}), variant("static")),
        ("lighting-dynamic", AnyView(LightingPanel {}), variant("wave")),
        ("curve", AnyView(CurvePanel {}), model),
        ("settings", AnyView(SettingsMenu().background(Color(white: 0.16))), model),
        ("menu", AnyView(MenuContent()), model),
    ]
    for (name, view, m) in pages {
        let content = view
            .environment(m)
            .environment(\.snapshotMode, true)
            .padding(12)
            .background(NS.bg)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
