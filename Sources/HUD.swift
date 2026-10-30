import AppKit

/// A quiet status pill at the bottom of the screen: working → done (click to reveal) or error.
/// It rises from the bottom edge and leaves the same way.
@MainActor
final class HUD {
    enum State { case working, done, error, info }

    var onClick: (() -> Void)?

    private static let size = NSSize(width: 360, height: 62)
    private let panel: NSPanel
    private let titleField: NSTextField
    private let subtitleField: NSTextField
    private let spinner: NSProgressIndicator
    private let glyph: NSImageView
    private var visible = false
    private var generation = 0
    private var state: State = .info

    init() {
        let s = HUD.size
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: s),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)

        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: s))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = HUD.pill(radius: 16)

        glyph = NSImageView(frame: NSRect(x: 18, y: 19, width: 24, height: 24))
        glyph.imageScaling = .scaleProportionallyUpOrDown

        spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 21, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        titleField = NSTextField(labelWithString: "")
        titleField.frame = NSRect(x: 56, y: 32, width: 288, height: 18)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = Palette.text
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1

        subtitleField = NSTextField(labelWithString: "")
        subtitleField.frame = NSRect(x: 56, y: 13, width: 288, height: 16)
        subtitleField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        subtitleField.textColor = Palette.muted
        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.maximumNumberOfLines = 1

        // Same glass as the wheel, lighter because the pill is smaller: a top sheen and a lit rim.
        let gloss = NSView(frame: material.bounds)
        gloss.wantsLayer = true
        let sheen = CAGradientLayer()
        sheen.frame = gloss.bounds
        sheen.cornerRadius = 16
        sheen.masksToBounds = true
        sheen.colors = [NSColor(white: 1, alpha: 0.5).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.45)
        gloss.layer?.addSublayer(sheen)
        gloss.layer?.cornerRadius = 16
        gloss.layer?.borderWidth = 1
        gloss.layer?.borderColor = NSColor(white: 1, alpha: 0.75).cgColor

        let catcher = ClickCatcher(frame: material.bounds)
        for v in [gloss, glyph, spinner, titleField, subtitleField, catcher] as [NSView] { material.addSubview(v) }
        panel.contentView = material

        catcher.onClick = { [weak self] in self?.clicked() }
    }

    func show(_ state: State, title: String, subtitle: String) {
        self.state = state
        generation += 1
        let g = generation

        titleField.stringValue = title
        subtitleField.stringValue = subtitle
        if state == .working {
            glyph.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            glyph.isHidden = false
            glyph.image = HUD.glyph(for: state)
            glyph.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                self.glyph.animator().alphaValue = 1
            }
        }
        if state == .done || state == .error {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(title). \(subtitle)",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }

        enter()

        var hold: Double?
        switch state {
        case .working: hold = nil
        case .done: hold = 3.4
        case .info: hold = 4.5
        case .error: hold = 6.5
        }
        if let hold = hold {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                if self.generation == g { self.leave() }
            }
        }
    }

    private func clicked() {
        if state == .done { onClick?() }
        leave()
    }

    private func enter() {
        let target = HUD.restingFrame()
        if !panel.isVisible {
            var start = target
            if !Motion.reduced { start.origin.y -= 14 }
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        visible = true
        // Animates from wherever it is now, so a re-show mid-exit simply turns around.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            self.panel.animator().setFrame(target, display: true)
            self.panel.animator().alphaValue = 1
        }
    }

    private func leave() {
        guard visible else { return }
        visible = false
        var end = panel.frame
        if !Motion.reduced { end.origin.y -= 14 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            self.panel.animator().setFrame(end, display: true)
            self.panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if !self.visible { self.panel.orderOut(nil) }
            }
        })
    }

    private static func restingFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: vf.midX - size.width / 2, y: vf.minY + 28, width: size.width, height: size.height)
    }

    private static func glyph(for state: State) -> NSImage? {
        switch state {
        case .done: return WheelView.symbol("checkmark.circle.fill", Palette.positive, 20)
        case .error: return WheelView.symbol("exclamationmark.circle.fill", Palette.negative, 20)
        case .info, .working: return Mark.image(side: 18, color: Palette.saffron)
        }
    }

    private static func pill(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}

/// Takes every click on the HUD, even while Convmog isn't the active app.
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
