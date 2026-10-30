import AppKit

/// Watches for file drags anywhere on the Mac without any special permissions.
/// A Finder drag writes the files to the system drag pasteboard; we poll its change
/// count plus the global mouse and modifier state at 120 Hz, so the wheel appears
/// within a frame of Shift going down.
@MainActor
final class DragWatcher: NSObject {
    var onShow: (([URL], Bool, NSPoint) -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var onEnd: (() -> Void)?

    private let board = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var mouseWasDown = false
    private var countAtMouseDown = 0
    private var dragged: [URL]?
    private var showing = false
    private var toolsMode = false

    func start() {
        let t = Timer(timeInterval: 1.0 / 120.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)

        guard down else {
            if mouseWasDown { finishDrag() }
            mouseWasDown = false
            return
        }

        if !mouseWasDown {
            mouseWasDown = true
            countAtMouseDown = board.changeCount   // a drag writes the pasteboard only after the pointer moves, so later
            dragged = nil
        }

        if dragged == nil, board.changeCount != countAtMouseDown {
            let urls = (board.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty { dragged = urls }
        }
        guard let urls = dragged else { return }

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)

        if !showing {
            if shift {
                showing = true
                toolsMode = option
                onShow?(urls, option, NSEvent.mouseLocation)
            }
        } else if option != toolsMode {
            toolsMode = option
            onModeChange?(option)
        }
    }

    private func finishDrag() {
        dragged = nil
        if showing {
            showing = false
            onEnd?()
        }
    }
}
