import AppKit

/// The crop window. It opens beside where the wheel was, showing the picture with the empty edges already
/// trimmed as a starting point. Drag the corners or edges to resize, drag inside to move, drag anywhere else
/// for a new area. Return or Done crops; Esc or Cancel leaves the file alone. Several files are asked one by one.
@MainActor
final class CropPanel: NSObject {
    static let shared = CropPanel()

    typealias Pick = (url: URL, area: CGRect)
    typealias Preview = (image: CGImage, start: CGRect, size: CGSize, unit: String)

    private var panel: KeyPanel?
    private var view: CropView?
    private var readout: NSTextField?
    private var current: (url: URL, size: CGSize, unit: String)?
    private var pending: [URL] = []
    private var picks: [Pick] = []
    private var total = 0
    private var anchor = NSPoint.zero
    private var picked: (@MainActor ([Pick]) -> Void)?
    private var failed: (@MainActor (Error) -> Void)?

    func choose(_ urls: [URL], picked: @escaping @MainActor ([Pick]) -> Void, failed: @escaping @MainActor (Error) -> Void) {
        hidePanel()
        pending = urls
        picks = []
        total = urls.count
        anchor = NSEvent.mouseLocation
        self.picked = picked
        self.failed = failed
        next()
    }

    private func next() {
        guard !pending.isEmpty else { return finish() }
        let url = pending.removeFirst()
        // Previews of big photos and Word documents take a moment; build them off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = Result { try Engine.cropPreview(url) }
            Task { @MainActor in
                switch preview {
                case .success(let p): self.show(url, p)
                case .failure(let error):
                    self.failed?(error)
                    self.next()
                }
            }
        }
    }

    private func finish() {
        if !picks.isEmpty { picked?(picks) }
        picks = []
        picked = nil
        failed = nil
    }

    @objc private func done() {
        guard let c = current, let v = view else { return }
        picks.append((url: c.url, area: v.area))
        hidePanel()
        next()
    }

    @objc private func cancel() {
        hidePanel()
        next()
    }

    // MARK: The window

    private func show(_ url: URL, _ p: Preview) {
        hidePanel()
        current = (url, p.size, p.unit)
        let pad: CGFloat = 14, bar: CGFloat = 54
        let iw = CGFloat(p.image.width), ih = CGFloat(p.image.height)
        let k = min(520 / iw, 400 / ih)
        let pictureW = max(iw * k, 340), pictureH = ih * k
        let size = NSSize(width: pictureW + pad * 2, height: pictureH + pad + bar)

        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)   // white glass, like the wheel

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
            return true
        }

        let crop = CropView(frame: NSRect(x: pad, y: bar, width: pictureW, height: pictureH), image: p.image, start: p.start)
        crop.onChange = { [weak self] _ in self?.updateReadout() }
        crop.onConfirm = { [weak self] in self?.done() }

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: pad + 2, y: 18, width: size.width - pad * 2 - 190, height: 18)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = Palette.text
        label.lineBreakMode = .byTruncatingMiddle

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.bezelColor = Palette.saffron
        doneButton.frame = NSRect(x: size.width - pad - 84, y: 13, width: 84, height: 30)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: size.width - pad - 84 - 8 - 84, y: 13, width: 84, height: 30)

        for v in [crop, label, cancelButton, doneButton] as [NSView] { glass.addSubview(v) }
        panel.contentView = glass

        self.panel = panel
        self.view = crop
        self.readout = label
        updateReadout()

        panel.setFrameOrigin(placement(for: size))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(crop)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    /// Beside where the wheel was: to the right of the cursor, or to the left when that runs off screen.
    private func placement(for size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.x + 48
        if x + size.width > vf.maxX { x = anchor.x - 48 - size.width }
        let y = anchor.y - size.height / 2
        return NSPoint(x: min(max(x, vf.minX + 8), vf.maxX - size.width - 8),
                       y: min(max(y, vf.minY + 8), vf.maxY - size.height - 8))
    }

    private func updateReadout() {
        guard let c = current, let v = view else { return }
        let a = v.area
        let w = Int((a.width * c.size.width).rounded()), h = Int((a.height * c.size.height).rounded())
        let count = total > 1 ? "  ·  \(total - pending.count) of \(total)" : ""
        readout?.stringValue = "\(c.url.lastPathComponent)  ·  \(w) × \(h) \(c.unit)\(count)"
    }

    private func hidePanel() {
        guard let p = panel else { return }
        panel = nil
        view = nil
        p.orderOut(nil)
    }
}

/// A borderless panel that can still take Return and Esc, without pulling the app to the front.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The picture with a movable, resizable crop area over it. `area` is 0…1 of the picture, top-left origin.
@MainActor
final class CropView: NSView {
    var onChange: ((CGRect) -> Void)?
    var onConfirm: (() -> Void)?

    private enum Grab { case none, move(CGVector), resize(left: Bool, right: Bool, bottom: Bool, top: Bool), draw(CGPoint) }

    private let image: CGImage
    private var sel = CGRect.zero        // the area in view points, y up
    private var before = CGRect.zero
    private var grab = Grab.none
    private let minSide: CGFloat = 12

    init(frame: NSRect, image: CGImage, start: CGRect) {
        self.image = image
        super.init(frame: frame)
        sel = toView(start)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Crop area. Drag to change it, Return to crop, Escape to cancel.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The picture fitted into the view, centred.
    private var picture: CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let k = min(bounds.width / iw, bounds.height / ih)
        let w = iw * k, h = ih * k
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    var area: CGRect {
        let p = picture
        return CGRect(x: (sel.minX - p.minX) / p.width, y: 1 - (sel.maxY - p.minY) / p.height,
                      width: sel.width / p.width, height: sel.height / p.height)
    }

    private func toView(_ a: CGRect) -> CGRect {
        let p = picture
        return CGRect(x: p.minX + a.minX * p.width, y: p.minY + (1 - a.maxY) * p.height,
                      width: a.width * p.width, height: a.height * p.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = picture
        ctx.interpolationQuality = .high
        ctx.draw(image, in: p)

        // Dim what will be cut away.
        ctx.addRect(p)
        ctx.addRect(sel)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.fillPath(using: .evenOdd)

        // Faint thirds, to help framing.
        let thirds: [CGFloat] = [1.0 / 3, 2.0 / 3]
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.4).cgColor)
        ctx.setLineWidth(0.5)
        for f in thirds {
            let x = sel.minX + sel.width * f, y = sel.minY + sel.height * f
            ctx.move(to: CGPoint(x: x, y: sel.minY))
            ctx.addLine(to: CGPoint(x: x, y: sel.maxY))
            ctx.move(to: CGPoint(x: sel.minX, y: y))
            ctx.addLine(to: CGPoint(x: sel.maxX, y: y))
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(sel.insetBy(dx: 0.75, dy: 0.75))

        // Corner grips.
        let g = min(16, sel.width / 3, sel.height / 3)
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (sel.minX, sel.minY, 1, 1), (sel.maxX, sel.minY, -1, 1), (sel.minX, sel.maxY, 1, -1), (sel.maxX, sel.maxY, -1, -1),
        ]
        ctx.setLineWidth(3.5)
        ctx.setLineCap(.round)
        for (x, y, dx, dy) in corners {
            ctx.move(to: CGPoint(x: x + dx * g, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y + dy * g))
        }
        ctx.strokePath()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, sel.contains(p) { onConfirm?(); return }
        before = sel
        let t: CGFloat = 10
        let alongY = p.y > sel.minY - t && p.y < sel.maxY + t
        let alongX = p.x > sel.minX - t && p.x < sel.maxX + t
        let left = alongY && abs(p.x - sel.minX) < t
        let right = alongY && !left && abs(p.x - sel.maxX) < t
        let bottom = alongX && abs(p.y - sel.minY) < t
        let top = alongX && !bottom && abs(p.y - sel.maxY) < t
        if left || right || bottom || top {
            grab = .resize(left: left, right: right, bottom: bottom, top: top)
        } else if sel.contains(p) {
            grab = .move(CGVector(dx: p.x - sel.minX, dy: p.y - sel.minY))
        } else if picture.contains(p) {
            grab = .draw(p)
        } else {
            grab = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pic = picture
        let raw = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x: min(max(raw.x, pic.minX), pic.maxX), y: min(max(raw.y, pic.minY), pic.maxY))
        switch grab {
        case .none:
            return
        case .move(let offset):
            let x = min(max(raw.x - offset.dx, pic.minX), pic.maxX - sel.width)
            let y = min(max(raw.y - offset.dy, pic.minY), pic.maxY - sel.height)
            sel.origin = CGPoint(x: x, y: y)
        case .resize(let left, let right, let bottom, let top):
            var x0 = sel.minX, x1 = sel.maxX, y0 = sel.minY, y1 = sel.maxY
            if left { x0 = min(p.x, x1 - minSide) }
            if right { x1 = max(p.x, x0 + minSide) }
            if bottom { y0 = min(p.y, y1 - minSide) }
            if top { y1 = max(p.y, y0 + minSide) }
            sel = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        case .draw(let a):
            sel = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
        }
        needsDisplay = true
        onChange?(area)
    }

    override func mouseUp(with event: NSEvent) {
        // A click outside the area (not a drag) keeps the area it had.
        if sel.width < minSide || sel.height < minSide {
            sel = before
            needsDisplay = true
            onChange?(area)
        }
        grab = .none
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let t: CGFloat = 6
        addCursorRect(picture, cursor: .crosshair)
        addCursorRect(sel.insetBy(dx: t, dy: t), cursor: .openHand)
        addCursorRect(CGRect(x: sel.minX - t, y: sel.minY, width: t * 2, height: sel.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: sel.maxX - t, y: sel.minY, width: t * 2, height: sel.height), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: sel.minX, y: sel.minY - t, width: sel.width, height: t * 2), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: sel.minX, y: sel.maxY - t, width: sel.width, height: t * 2), cursor: .resizeUpDown)
    }
}
