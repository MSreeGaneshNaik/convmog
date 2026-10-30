import AppKit

/// Watches for file drags anywhere on the Mac without any special permissions.
/// A Finder drag writes the files to the system drag pasteboard; we watch its change count plus the
/// global mouse and modifier state. While the mouse is up we look 8 times a second, which is cheap
/// and lets the Mac rest; the moment it goes down we look 120 times a second, so the wheel appears
/// within a frame of Shift going down.
@MainActor
final class DragWatcher: NSObject {
    var onShow: (([URL], Bool, NSPoint) -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var onEnd: (() -> Void)?

    private let board = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var mouseWasDown = false
    private var countWhileUp = 0      // the drag pasteboard as it was before the mouse went down
    private var countRead = 0         // the last change we read, so a text drag isn't re-read every tick
    private var dragged: [URL]?
    private var showing = false
    private var toolsMode = false

    func start() {
        countWhileUp = board.changeCount
        pace(fast: false)
    }

    private func pace(fast: Bool) {
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 120.0 : 1.0 / 8.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = fast ? 0.002 : 0.04
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)

        guard down else {
            if mouseWasDown {
                finishDrag()
                pace(fast: false)
            }
            mouseWasDown = false
            // Only ever sampled with the button up, so it always predates the next drag, even when the slow
            // tick notices the mouse-down an eighth of a second late.
            countWhileUp = board.changeCount
            return
        }

        if !mouseWasDown {
            mouseWasDown = true
            countRead = countWhileUp
            dragged = nil
            pace(fast: true)
        }

        if dragged == nil {
            let count = board.changeCount
            if count != countRead {
                countRead = count
                let urls = (board.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                if !urls.isEmpty { dragged = urls }
            }
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
