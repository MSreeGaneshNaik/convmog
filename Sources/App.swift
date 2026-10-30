import AppKit
import ServiceManagement

// Convmog — hold Shift while dragging any file and a wheel of formats blooms around your cursor.
// Release on a wedge: the converted file lands next to the original. Add Option for tools.

@main
@MainActor
enum ConvmogMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let watcher: DragWatcher
    private let wheel: WheelController
    private let hud: HUD
    private let work = DispatchQueue(label: "convmog.work", qos: .userInitiated)
    private var lastOutputs: [URL] = []
    private var queue: [(id: Int, title: String, subtitle: String)] = []   // jobs not finished, in run order
    private var nextID = 0

    override init() {
        watcher = DragWatcher()
        wheel = WheelController()
        hud = HUD()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        watcher.onShow = { [weak self] urls, tools, point in self?.openWheel(urls, tools: tools, at: point) }
        watcher.onModeChange = { [weak self] tools in self?.wheel.setToolsMode(tools) }
        watcher.onEnd = { [weak self] in self?.wheel.dismissAfterDrag() }
        wheel.onPick = { [weak self] action, urls in self?.run(action, on: urls) }
        hud.onClick = { [weak self] in self?.revealLast() }
        watcher.start()

        if !UserDefaults.standard.bool(forKey: "convmog.welcomed") {
            UserDefaults.standard.set(true, forKey: "convmog.welcomed")
            hud.show(.info, title: "Convmog is ready", subtitle: "Hold ⇧ while dragging any file")
        }
    }

    // MARK: Wheel

    private func openWheel(_ urls: [URL], tools: Bool, at point: NSPoint) {
        let convert = Catalog.actions(for: urls, tools: false)
        let toolActions = Catalog.actions(for: urls, tools: true)
        guard !convert.isEmpty || !toolActions.isEmpty else { return }
        wheel.show(urls: urls, convert: convert, tools: toolActions, toolsMode: tools, at: point)
        if convert.isEmpty, Catalog.wantsFFmpeg(urls) {
            hud.show(.info, title: "More formats with ffmpeg", subtitle: "brew install ffmpeg")
        }
    }

    // MARK: Work

    private func run(_ action: Action, on urls: [URL]) {
        switch action.work {
        case .now(let job): start(job, action.verb, on: urls)
        case .ask(let ask): ask(urls) { [weak self] job in self?.start(job, action.verb, on: urls) }
        }
    }

    private func start(_ job: @escaping Job, _ verb: String, on urls: [URL]) {
        nextID += 1
        queue.append((nextID, verb, Self.describe(urls)))
        if queue.count == 1 { hud.show(.working, title: verb, subtitle: Self.describe(urls)) }
        let before = Self.bytes(urls)
        work.async {
            let result = Result { try job(urls) }
            Task { @MainActor in self.finish(result, before: before) }
        }
    }

    private func finish(_ result: Result<[URL], Error>, before: Int64) {
        if !queue.isEmpty { queue.removeFirst() }   // the work queue is serial, so jobs finish in order
        defer { showNextJob() }
        switch result {
        case .success(let outputs):
            lastOutputs = outputs
            let title = outputs.count == 1 ? outputs[0].lastPathComponent : "\(outputs.count) files ready"
            var subtitle = "Click to show in Finder"
            let after = Self.bytes(outputs)
            if before > 0, after > 0 {
                let f = ByteCountFormatter()
                f.countStyle = .file
                let change = Int(((Double(after) / Double(before) - 1) * 100).rounded())
                let delta = change == 0 ? "" : (change < 0 ? "  ·  \(change)%" : "  ·  +\(change)%")
                subtitle = "\(f.string(fromByteCount: before)) → \(f.string(fromByteCount: after))\(delta)"
            }
            hud.show(.done, title: title, subtitle: subtitle)
            if UserDefaults.standard.object(forKey: "convmog.sounds") as? Bool ?? true {
                let s = NSSound(named: "Pop")
                s?.volume = 0.35
                s?.play()
            }
        case .failure(let error):
            if let partial = error as? PartialFailure, !partial.made.isEmpty { lastOutputs = partial.made }
            hud.show(.error, title: "Couldn't finish that", subtitle: error.localizedDescription)
        }
    }

    /// After a result has had a moment on screen, the pill goes back to the job still running.
    private func showNextJob() {
        guard let next = queue.first else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self.queue.first?.id == next.id { self.hud.show(.working, title: next.title, subtitle: next.subtitle) }
        }
    }

    private static func describe(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
    }

    /// Total size of plain files; 0 when any item is a folder, so we never show a misleading delta.
    private static func bytes(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
            if v.isDirectory == true { return 0 }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }

    @objc private func revealLast() {
        guard !lastOutputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastOutputs)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Mark.image(side: 16)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(Self.note("Hold ⇧ while dragging a file"))
        menu.addItem(Self.note("Add ⌥ to switch to tools"))
        menu.addItem(.separator())
        menu.addItem(Self.note(Engine.ffmpeg != nil ? "Engines: macOS + ffmpeg" : "Engines: macOS built-ins"))
        if Engine.ffmpeg == nil { menu.addItem(Self.note("brew install ffmpeg for MP3, WebM, MKV…")) }
        if let commit = Bundle.main.object(forInfoDictionaryKey: "ConvmogCommit") as? String {
            menu.addItem(Self.note("Version \(commit.prefix(7))"))
        }
        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "Show Last Result", action: lastOutputs.isEmpty ? nil : #selector(revealLast), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let sounds = NSMenuItem(title: "Play Sound When Done", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = (UserDefaults.standard.object(forKey: "convmog.sounds") as? Bool ?? true) ? .on : .off
        menu.addItem(sounds)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Convmog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleSounds() {
        let on = UserDefaults.standard.object(forKey: "convmog.sounds") as? Bool ?? true
        UserDefaults.standard.set(!on, forKey: "convmog.sounds")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.show(.error, title: "Couldn't change login setting", subtitle: error.localizedDescription)
        }
    }
}

// MARK: - Palette (white glass, black letters, one saffron accent)

@MainActor
enum Palette {
    nonisolated static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: alpha)
    }
    static let text = hex(0x1D1D1F)                     // black letters on white glass
    static let muted = hex(0x5E5E63)
    static let saffron = hex(0xFF8A1F)                  // the one accent: the wedge you're aiming at
    static let saffronInk = hex(0x1A1206)
    static let ink = hex(0x1D1D1F)                      // tools mode lights a black wedge…
    static let inkText = NSColor.white                  // …with white letters
    static let well = NSColor.black                     // wedges and hub, at low opacity over the glass
    static let rim = NSColor(white: 1, alpha: 0.3)      // inner thickness line on the glass
    static let lens = NSColor(white: 1, alpha: 0.5)     // the raised hub
    static let lensHover = NSColor(white: 1, alpha: 0.72)
    static let positive = hex(0x2FA866)
    static let negative = hex(0xD93A56)
}

// MARK: - The mark (the Jericho petals, drawn as vectors so it's sharp at any size)

enum Mark {
    /// Six quarter-round petals on a 256 grid, y pointing down.
    static let petals = [
        "M 0 0 C 35.346 0 64 28.654 64 64 L 64 128 C 28.654 128 0 99.346 0 64 Z",
        "M 192 64 C 192 99.346 163.346 128 128 128 C 92.654 128 64 99.346 64 64 L 64 0 C 99.346 0 128 28.654 128 64 C 128 28.654 156.654 0 192 0 Z",
        "M 256 64 C 256 99.346 227.346 128 192 128 L 192 64 C 192 28.654 220.654 0 256 0 Z",
        "M 64 192 C 64 227.346 35.346 256 0 256 L 0 192 C 0 156.654 28.654 128 64 128 Z",
        "M 128 128 C 163.346 128 192 156.654 192 192 L 192 256 C 156.654 256 128 227.346 128 192 C 128 227.346 99.346 256 64 256 L 64 192 C 64 156.654 92.654 128 128 128 Z",
        "M 192 128 C 227.346 128 256 156.654 256 192 L 256 256 C 220.654 256 192 227.346 192 192 Z",
    ]

    /// The petals as one path, `side` points wide, for a flipped (y-down) context.
    static func path(side: CGFloat) -> NSBezierPath {
        let s = side / 256, path = NSBezierPath()
        for d in petals {
            let t = d.split(separator: " ").map(String.init)
            var i = 0
            func point() -> NSPoint {
                defer { i += 2 }
                return NSPoint(x: CGFloat(Double(t[i])!) * s, y: CGFloat(Double(t[i + 1])!) * s)
            }
            while i < t.count {
                let command = t[i]
                i += 1
                switch command {
                case "M": path.move(to: point())
                case "L": path.line(to: point())
                case "C":
                    let c1 = point(), c2 = point()
                    path.curve(to: point(), controlPoint1: c1, controlPoint2: c2)
                default: path.close()
                }
            }
        }
        return path
    }

    /// No colour → a template image that follows the menu bar's light and dark.
    static func image(side: CGFloat, color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            (color ?? .black).setFill()
            Mark.path(side: rect.width).fill()
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "Convmog"
        return image
    }
}

// MARK: - Motion (Apple's damping-ratio + response springs, mapped to Core Animation)

@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// response = seconds to reach the target; damping 1.0 = no overshoot.
    static func spring(_ keyPath: String, from: Any?, to: Any, response: Double = 0.32, damping: Double = 1.0) -> CAAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 4 * .pi * damping / response
        a.fromValue = from
        a.toValue = to
        a.duration = a.settlingDuration
        return a
    }

    static func fade(_ keyPath: String, from: Any?, to: Any, duration: Double = 0.14) -> CAAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        return a
    }

    /// Sets a layer property and animates to it from whatever is on screen right now (interruptible).
    static func animate(_ layer: CALayer, _ keyPath: String, to value: Any, spring: Bool = true, response: Double = 0.32, damping: Double = 1.0, duration: Double = 0.14) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        let anim = (spring && !reduced)
            ? Motion.spring(keyPath, from: from, to: value, response: response, damping: damping)
            : Motion.fade(keyPath, from: from, to: value, duration: duration)
        layer.add(anim, forKey: keyPath)
    }

    static func still(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
