import AppKit

// MARK: - Controller: owns the floating panel and the material disc

@MainActor
final class WheelController {
    var onPick: ((Action, [URL]) -> Void)?

    private let panel: NSPanel
    private let disc: NSVisualEffectView
    private let wheel: WheelView
    private var urls: [URL] = []
    private var convert: [Action] = []
    private var tools: [Action] = []
    private var toolsMode = false
    private var isOpen = false
    private var generation = 0

    init() {
        let size = WheelView.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .aqua)   // white glass even in Dark Mode

        let root = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        root.wantsLayer = true

        let d = WheelView.discRadius * 2
        disc = NSVisualEffectView(frame: NSRect(x: (size - d) / 2, y: (size - d) / 2, width: d, height: d))
        disc.material = .popover
        disc.blendingMode = .behindWindow
        disc.state = .active
        disc.maskImage = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }

        wheel = WheelView(frame: root.bounds)
        root.addSubview(disc)
        root.addSubview(wheel)
        panel.contentView = root

        wheel.onDrop = { [weak self] index in self?.pick(index) }
    }

    func show(urls: [URL], convert: [Action], tools: [Action], toolsMode: Bool, at point: NSPoint) {
        self.urls = urls
        self.convert = convert
        self.tools = tools
        self.toolsMode = convert.isEmpty ? true : (tools.isEmpty ? false : toolsMode)
        generation += 1

        // Centre on the cursor; keep the whole disc on screen.
        let size = WheelView.size
        let margin = size / 2 - WheelView.discRadius
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX - margin), f.maxX - size + margin)
            origin.y = min(max(origin.y, f.minY - margin), f.maxY - size + margin)
        }
        panel.setFrameOrigin(origin)

        wheel.configure(urls: urls,
                        actions: self.toolsMode ? tools : convert,
                        toolsMode: self.toolsMode,
                        canSwitch: !convert.isEmpty && !tools.isEmpty)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            self.panel.animator().alphaValue = 1
        }
        wheel.bloom()
        isOpen = true
    }

    func setToolsMode(_ on: Bool) {
        guard isOpen, !convert.isEmpty, !tools.isEmpty, on != toolsMode else { return }
        toolsMode = on
        wheel.setActions(on ? tools : convert, toolsMode: on, canSwitch: true, animated: true)
    }

    /// Called on mouse-up. Waits a beat so a drop on a wedge (delivered just after) wins the race.
    func dismissAfterDrag() {
        guard isOpen else { return }
        let g = generation
        Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            if self.generation == g { self.dismiss() }
        }
    }

    func dismiss(picked: Bool = false) {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        let g = generation
        wheel.collapse(picked: picked)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = picked ? 0.2 : 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if self.generation == g { self.panel.orderOut(nil) }
            }
        })
    }

    private func pick(_ index: Int) {
        let actions = toolsMode ? tools : convert
        guard actions.indices.contains(index) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        let chosen = actions[index]
        let files = urls
        dismiss(picked: true)
        onPick?(chosen, files)
    }
}

// MARK: - The wheel itself: a layer-hosting view that is also the drop target

@MainActor
final class WheelView: NSView {
    static let size: CGFloat = 440
    static let discRadius: CGFloat = 196
    static let outer: CGFloat = 172
    static let inner: CGFloat = 66
    static let hubRadius: CGFloat = 54

    var onDrop: ((Int) -> Void)?

    private let root = CALayer()
    private let ring = CALayer()
    private var host = CALayer()
    private let sheen = CAGradientLayer()      // light across the top of the glass
    private let shade = CAGradientLayer()      // thickness at the bottom edge
    private let rimLight = CAGradientLayer()   // the rim catching light: bright on top, softer below
    private let edges = CAShapeLayer()         // inner thickness line
    private let hub = CALayer()
    private let hubWell = CAShapeLayer()
    private let icon = CALayer()
    private let badge = CAShapeLayer()
    private let badgeText = CATextLayer()
    private let title = CATextLayer()
    private let hint = CATextLayer()

    private var segments: [Segment] = []
    private var actions: [Action] = []
    private var toolsMode = false
    private var canSwitch = false
    private var fileName = ""
    private var hovered: Int?   // nil = outside, -1 = hub, n = wedge

    private var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var accent: NSColor { toolsMode ? Palette.ink : Palette.saffron }
    private var ink: NSColor { toolsMode ? Palette.inkText : Palette.saffronInk }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        buildStaticLayers()
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Morph conversion wheel")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildStaticLayers() {
        let c = centre
        Motion.still {
            ring.frame = bounds
            host.frame = bounds
            hub.frame = bounds
            root.addSublayer(ring)
            ring.addSublayer(host)
            ring.addSublayer(hub)

            // Depth on the glass, beneath the wedges.
            let r = Self.discRadius
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            for g in [sheen, shade, rimLight] {
                g.frame = disc
                g.cornerRadius = r
                g.masksToBounds = true
            }
            sheen.colors = [NSColor(white: 1, alpha: 0.55).cgColor, NSColor(white: 1, alpha: 0).cgColor]
            sheen.startPoint = CGPoint(x: 0.5, y: 1)   // y points up on macOS
            sheen.endPoint = CGPoint(x: 0.5, y: 0.5)
            shade.colors = [NSColor(srgbRed: 0.04, green: 0.13, blue: 0.2, alpha: 0.09).cgColor, NSColor.clear.cgColor]
            shade.startPoint = CGPoint(x: 0.5, y: 0)
            shade.endPoint = CGPoint(x: 0.5, y: 0.4)
            rimLight.colors = [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 1, alpha: 0.25).cgColor, NSColor(white: 1, alpha: 0.7).cgColor]
            rimLight.locations = [0, 0.55, 1]
            rimLight.startPoint = CGPoint(x: 0.5, y: 1)
            rimLight.endPoint = CGPoint(x: 0.5, y: 0)
            let ringMask = CAShapeLayer()
            ringMask.frame = CGRect(origin: .zero, size: disc.size)
            ringMask.path = CGPath(ellipseIn: ringMask.bounds.insetBy(dx: 1.1, dy: 1.1), transform: nil)
            ringMask.fillColor = nil
            ringMask.strokeColor = NSColor.black.cgColor
            ringMask.lineWidth = 2.2
            rimLight.mask = ringMask
            edges.frame = bounds
            edges.path = CGPath(ellipseIn: disc.insetBy(dx: 7, dy: 7), transform: nil)
            edges.fillColor = nil
            edges.strokeColor = Palette.rim.cgColor
            edges.lineWidth = 1
            for (i, l) in [sheen, shade, edges, rimLight].enumerated() { root.insertSublayer(l, at: UInt32(i)) }

            hubWell.frame = bounds
            hubWell.path = CGPath(ellipseIn: CGRect(x: c.x - Self.hubRadius, y: c.y - Self.hubRadius,
                                                    width: Self.hubRadius * 2, height: Self.hubRadius * 2),
                                  transform: nil)
            // The hub is a raised glass lens.
            hubWell.fillColor = Palette.lens.cgColor
            hubWell.shadowPath = hubWell.path
            hubWell.shadowColor = NSColor.black.cgColor
            hubWell.shadowOpacity = 0.12
            hubWell.shadowRadius = 6
            hubWell.shadowOffset = CGSize(width: 0, height: -2)
            hub.addSublayer(hubWell)
            let lens = CGRect(x: c.x - Self.hubRadius, y: c.y - Self.hubRadius, width: Self.hubRadius * 2, height: Self.hubRadius * 2)
            let lensSheen = CAGradientLayer()
            lensSheen.frame = lens
            lensSheen.cornerRadius = Self.hubRadius
            lensSheen.masksToBounds = true
            lensSheen.colors = [NSColor(white: 1, alpha: 0.6).cgColor, NSColor(white: 1, alpha: 0).cgColor]
            lensSheen.startPoint = CGPoint(x: 0.5, y: 1)
            lensSheen.endPoint = CGPoint(x: 0.5, y: 0.45)
            hub.addSublayer(lensSheen)
            let lensRim = CAShapeLayer()
            lensRim.frame = bounds
            lensRim.path = CGPath(ellipseIn: lens.insetBy(dx: 0.6, dy: 0.6), transform: nil)
            lensRim.fillColor = nil
            lensRim.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
            lensRim.lineWidth = 1.2
            hub.addSublayer(lensRim)

            icon.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
            icon.position = CGPoint(x: c.x, y: c.y + 15)
            icon.contentsGravity = .resizeAspect
            hub.addSublayer(icon)

            badge.bounds = CGRect(x: 0, y: 0, width: 20, height: 15)
            badge.path = CGPath(roundedRect: badge.bounds, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
            badge.position = CGPoint(x: c.x + 17, y: c.y + 29)
            hub.addSublayer(badge)
            Self.style(badgeText, font: .systemFont(ofSize: 9.5, weight: .bold), color: Palette.saffronInk, width: 20)
            badgeText.position = CGPoint(x: 10, y: 7.5)
            badge.addSublayer(badgeText)

            Self.style(title, font: .systemFont(ofSize: 11, weight: .semibold), color: Palette.text, width: 92)
            title.truncationMode = .middle
            title.position = CGPoint(x: c.x, y: c.y - 12)
            hub.addSublayer(title)

            Self.style(hint, font: .systemFont(ofSize: 9.5, weight: .medium), color: Palette.muted, width: 92)   // the hub is ~93pt wide here
            hint.position = CGPoint(x: c.x, y: c.y - 27)
            hub.addSublayer(hint)
        }
    }

    // MARK: Configure / modes

    func configure(urls: [URL], actions: [Action], toolsMode: Bool, canSwitch: Bool) {
        fileName = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        let scale = backing
        Motion.still {
            icon.contents = urls.count == 1
                ? NSWorkspace.shared.icon(forFile: urls[0].path)
                : NSWorkspace.shared.icon(forFiles: urls.map(\.path))
            icon.contentsScale = scale
            badge.isHidden = urls.count < 2
            badge.fillColor = Palette.saffron.cgColor
            badgeText.string = urls.count > 99 ? "99+" : "\(urls.count)"
            for t in [title, hint, badgeText] { t.contentsScale = scale }
            hubWell.fillColor = Palette.lens.cgColor
        }
        hovered = nil
        setActions(actions, toolsMode: toolsMode, canSwitch: canSwitch, animated: false)
    }

    func setActions(_ actions: [Action], toolsMode: Bool, canSwitch: Bool, animated: Bool) {
        self.actions = actions
        self.toolsMode = toolsMode
        self.canSwitch = canSwitch
        let wasHovering = hovered
        hovered = (wasHovering == -1) ? -1 : nil

        let fresh = CALayer()
        let made = buildSegments()
        Motion.still {
            fresh.frame = bounds
            made.forEach { fresh.addSublayer($0.group) }
            ring.insertSublayer(fresh, below: hub)
        }
        let old = host
        host = fresh
        segments = made

        if animated {
            CATransaction.begin()
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            Motion.animate(old, "opacity", to: 0.0, spring: false, duration: 0.1)
            CATransaction.commit()
            fresh.add(Motion.fade("opacity", from: 0.0, to: 1.0, duration: 0.14), forKey: "opacity")
            if !Motion.reduced {
                fresh.add(Motion.spring("transform.scale", from: 0.94, to: 1.0, response: 0.3), forKey: "transform.scale")
            }
        } else {
            old.removeFromSuperlayer()
        }
        refreshHub()
    }

    private func buildSegments() -> [Segment] {
        let n = actions.count
        guard n > 0 else { return [] }
        let sweep = 2 * CGFloat.pi / CGFloat(n)
        let scale = backing
        return actions.enumerated().map { i, action in
            Segment(action: action, bounds: bounds, centre: centre,
                    mid: CGFloat.pi / 2 - CGFloat(i) * sweep, sweep: sweep, count: n,
                    scale: scale, ink: ink)
        }
    }

    // MARK: Motion moments

    /// The ring blooms out of the cursor: critically damped, no overshoot.
    func bloom() {
        ring.removeAllAnimations()
        Motion.still {
            ring.opacity = 1
            ring.transform = CATransform3DIdentity
        }
        ring.add(Motion.fade("opacity", from: 0.0, to: 1.0, duration: 0.12), forKey: "opacity")
        if !Motion.reduced {
            ring.add(Motion.spring("transform.scale", from: 0.82, to: 1.0, response: 0.34), forKey: "transform.scale")
        }
    }

    /// Cancel folds back into the cursor along the same path; a pick pushes the chosen wedge out.
    func collapse(picked: Bool) {
        if picked, let i = hovered, segments.indices.contains(i) {
            Motion.animate(segments[i].group, "transform.scale", to: 1.1, response: 0.22)
        } else if !Motion.reduced {
            Motion.animate(ring, "transform.scale", to: 0.9, response: 0.24)
        }
        Motion.animate(ring, "opacity", to: 0.0, spring: false, duration: picked ? 0.2 : 0.14)
    }

    // MARK: Hover

    private func setHovered(_ next: Int?) {
        guard next != hovered else { return }
        if let old = hovered, segments.indices.contains(old) {
            segments[old].setActive(false, accent: accent)
        }
        hovered = next
        if let new = next, segments.indices.contains(new) {
            segments[new].setActive(true, accent: accent)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        Motion.animate(hubWell, "fillColor", to: (next == -1 ? Palette.lensHover : Palette.lens).cgColor, spring: false, duration: 0.12)
        refreshHub()
    }

    private func refreshHub() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        if let i = hovered, actions.indices.contains(i) {
            let a = actions[i]
            title.string = a.symbol == nil ? "To \(a.label)" : a.label
            title.foregroundColor = Palette.text.cgColor
            hint.string = "Release to apply"
        } else {
            title.string = fileName
            title.foregroundColor = Palette.text.cgColor
            if canSwitch {
                hint.string = toolsMode ? "Let go of ⌥" : "Hold ⌥ for tools"
            } else {
                hint.string = toolsMode ? "Tools" : "Drop on a format"
            }
        }
        CATransaction.commit()
    }

    private func zone(at p: NSPoint) -> Int? {
        let dx = p.x - centre.x, dy = p.y - centre.y
        let d = (dx * dx + dy * dy).squareRoot()
        if d <= Self.hubRadius + 4 { return -1 }
        guard !actions.isEmpty, d <= Self.discRadius + 32 else { return nil }
        return Self.wedge(dx: dx, dy: dy, count: actions.count)
    }

    /// Wedge 0 is centred at 12 o'clock, then clockwise. y points up.
    nonisolated static func wedge(dx: CGFloat, dy: CGFloat, count: Int) -> Int {
        let sweep = 2 * CGFloat.pi / CGFloat(count)
        var offset = (CGFloat.pi / 2 + sweep / 2 - atan2(dy, dx)).truncatingRemainder(dividingBy: 2 * .pi)
        if offset < 0 { offset += 2 * .pi }
        return min(Int(offset / sweep), count - 1)
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHovered(nil) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let i = hovered, i >= 0 { return true }
        return false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = hovered, i >= 0 else { return false }
        Task { @MainActor in self.onDrop?(i) }
        return true
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        setHovered(zone(at: p))
        if let i = hovered, i >= 0 { return .copy }
        return []
    }

    // MARK: Text helpers

    static func style(_ t: CATextLayer, font: NSFont, color: NSColor, width: CGFloat) {
        t.font = font
        t.fontSize = font.pointSize
        t.foregroundColor = color.cgColor
        t.alignmentMode = .center
        t.truncationMode = .end
        t.isWrapped = false
        t.bounds = CGRect(x: 0, y: 0, width: width, height: ceil(font.ascender - font.descender) + 1)
    }

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    static func symbol(_ name: String, _ color: NSColor, _ size: CGFloat) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(config)
    }
}

// MARK: - One wedge

@MainActor
final class Segment {
    let group = CALayer()
    private let shape = CAShapeLayer()
    private let gloss = CAGradientLayer()   // sheen on the lit wedge
    private let label = CATextLayer()
    private var detail: CATextLayer?
    private var symbol: CALayer?
    private var symbolIdle: NSImage?
    private var symbolActive: NSImage?
    private let ink: NSColor

    init(action: Action, bounds: CGRect, centre c: CGPoint, mid: CGFloat, sweep: CGFloat, count n: Int, scale: CGFloat, ink: NSColor) {
        self.ink = ink
        let ro = WheelView.outer, ri = WheelView.inner
        let rm = (ro + ri) / 2
        let p = CGPoint(x: c.x + cos(mid) * rm, y: c.y + sin(mid) * rm)
        let chord = n == 1 ? 120 : min(96, 2 * rm * sin(sweep / 2) - 12)

        Motion.still {
            group.frame = bounds
            shape.frame = bounds
            if n == 1 {
                let path = CGMutablePath()
                path.addEllipse(in: CGRect(x: c.x - ro, y: c.y - ro, width: ro * 2, height: ro * 2))
                path.addEllipse(in: CGRect(x: c.x - ri, y: c.y - ri, width: ri * 2, height: ri * 2))
                shape.path = path
                shape.fillRule = .evenOdd
                shape.lineWidth = 0
            } else {
                // Opaque fill + matching round-joined stroke = softly rounded corners;
                // layer opacity then tints it, so the overlap never shows.
                shape.path = Segment.wedge(centre: c, inner: ri + 2, outer: ro - 2, mid: mid, sweep: sweep, gap: 7)
                shape.lineWidth = 4
                shape.lineJoin = .round
            }
            shape.fillColor = Palette.well.cgColor
            shape.strokeColor = Palette.well.cgColor
            shape.opacity = 0.06
            shape.shadowPath = shape.path
            shape.shadowColor = NSColor.black.cgColor
            shape.shadowOffset = CGSize(width: 0, height: -6)
            shape.shadowRadius = 9
            shape.shadowOpacity = 0
            group.addSublayer(shape)

            if let path = shape.path {
                let box = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
                var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                let mask = CAShapeLayer()
                mask.path = path.copy(using: &shift)
                mask.fillRule = shape.fillRule
                mask.fillColor = NSColor.black.cgColor
                mask.strokeColor = NSColor.black.cgColor
                mask.lineWidth = shape.lineWidth
                mask.lineJoin = .round
                gloss.frame = box
                gloss.mask = mask
                gloss.colors = [NSColor(white: 1, alpha: 0.42).cgColor, NSColor(white: 1, alpha: 0).cgColor]
                gloss.startPoint = CGPoint(x: 0.5, y: 1)
                gloss.endPoint = CGPoint(x: 0.5, y: 0.4)
                gloss.opacity = 0
                group.addSublayer(gloss)
            }

            if let name = action.symbol, let idle = WheelView.symbol(name, Palette.text, 16) {
                symbolIdle = idle
                symbolActive = WheelView.symbol(name, ink, 16)
                let s = CALayer()
                s.contents = idle
                s.contentsGravity = .resizeAspect
                s.contentsScale = scale
                s.bounds = CGRect(origin: .zero, size: idle.size)
                s.position = CGPoint(x: p.x, y: p.y + 8)
                group.addSublayer(s)
                symbol = s
                WheelView.style(label, font: WheelView.rounded(11, .semibold), color: Palette.text, width: chord)
                label.string = action.label
                label.position = CGPoint(x: p.x, y: p.y - 11)
            } else {
                WheelView.style(label, font: WheelView.rounded(15, .bold), color: Palette.text, width: chord)
                label.string = action.label
                label.position = CGPoint(x: p.x, y: p.y + 6)
                let d = CATextLayer()
                WheelView.style(d, font: .systemFont(ofSize: 10, weight: .medium), color: Palette.muted, width: chord)
                d.string = action.detail
                d.position = CGPoint(x: p.x, y: p.y - 10)
                d.contentsScale = scale
                group.addSublayer(d)
                detail = d
            }
            label.contentsScale = scale
            group.addSublayer(label)
        }
    }

    func setActive(_ on: Bool, accent: NSColor) {
        Motion.animate(group, "transform.scale", to: on ? 1.06 : 1.0, response: 0.26)
        Motion.animate(shape, "opacity", to: on ? 1.0 : 0.06, spring: false, duration: 0.12)
        Motion.animate(shape, "shadowOpacity", to: on ? 0.28 : 0.0, spring: false, duration: 0.14)
        Motion.animate(gloss, "opacity", to: on ? 1.0 : 0.0, spring: false, duration: 0.12)
        Motion.animate(shape, "fillColor", to: (on ? accent : Palette.well).cgColor, spring: false, duration: 0.12)
        Motion.animate(shape, "strokeColor", to: (on ? accent : Palette.well).cgColor, spring: false, duration: 0.12)
        Motion.animate(label, "foregroundColor", to: (on ? ink : Palette.text).cgColor, spring: false, duration: 0.12)
        if let d = detail {
            Motion.animate(d, "foregroundColor", to: (on ? ink.withAlphaComponent(0.72) : Palette.muted).cgColor, spring: false, duration: 0.12)
        }
        if let s = symbol {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            s.add(fade, forKey: "contents")
            Motion.still { s.contents = on ? symbolActive : symbolIdle }
        }
    }

    /// An annular wedge whose gaps have parallel sides of constant width.
    static func wedge(centre c: CGPoint, inner ri: CGFloat, outer ro: CGFloat, mid: CGFloat, sweep: CGFloat, gap g: CGFloat) -> CGPath {
        let half = sweep / 2
        let dOut = asin(min(1, (g / 2) / ro))
        let dIn = asin(min(1, (g / 2) / ri))
        let path = CGMutablePath()
        path.addArc(center: c, radius: ro, startAngle: mid + half - dOut, endAngle: mid - half + dOut, clockwise: true)
        path.addArc(center: c, radius: ri, startAngle: mid - half + dIn, endAngle: mid + half - dIn, clockwise: false)
        path.closeSubpath()
        return path
    }
}
