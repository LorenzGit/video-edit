import AppKit

/// Owns the temporary menu-bar indicator shown while Reel records.
@MainActor
final class RecordingStatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let elapsedItem: NSMenuItem
    private let stopItem: NSMenuItem
    private let stop: () -> Void
    private var isClosed = false

    init(stop: @escaping () -> Void) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        elapsedItem = NSMenuItem(title: "Recording 00:00", action: nil, keyEquivalent: "")
        stopItem = NSMenuItem(
            title: "Stop Recording",
            action: #selector(stopRecording),
            keyEquivalent: "\u{1b}"
        )
        self.stop = stop
        super.init()

        let dot = Self.recordingDot()
        if let button = statusItem.button {
            button.image = dot
            button.imagePosition = .imageOnly
            button.toolTip = "Reel is recording — click for controls"
            button.setAccessibilityLabel("Reel is recording")
            button.setAccessibilityHelp("Click to view recording controls")
        }

        elapsedItem.image = dot
        elapsedItem.isEnabled = false
        stopItem.target = self
        stopItem.keyEquivalentModifierMask = [.command]

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(elapsedItem)
        menu.addItem(.separator())
        menu.addItem(stopItem)
        statusItem.menu = menu
    }

    func update(elapsed: TimeInterval) {
        let elapsedText = Self.format(elapsed)
        elapsedItem.title = "Recording \(elapsedText)"
        statusItem.button?.toolTip = "Reel is recording (\(elapsedText)) — click for controls"
    }

    func setFinishing() {
        elapsedItem.title = "Finishing recording…"
        stopItem.isEnabled = false
        statusItem.button?.toolTip = "Reel is finishing the recording"
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func stopRecording() {
        stop()
    }

    private static func recordingDot() -> NSImage {
        let image = NSImage(
            size: NSSize(width: 18, height: 18),
            flipped: false
        ) { _ in
            NSColor.systemRed.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: 4, y: 4, width: 10, height: 10)
            ).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func format(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
