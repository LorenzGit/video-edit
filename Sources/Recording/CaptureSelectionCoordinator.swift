import AppKit
import CoreGraphics
import SwiftUI

/// A display-relative rectangle selected by the user. ScreenCaptureKit expects
/// `sourceRect` in logical points with a top-left origin.
struct ScreenCaptureSelection {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let pointPixelScale: CGFloat
    let includeSystemAudio: Bool
}

@MainActor
final class CaptureSelectionCoordinator: NSObject {
    private var overlays: [CaptureOverlayPanel] = []
    private var activeView: CaptureSelectionView?
    private var controlsPanel: CaptureControlsPanel?
    private var keyMonitor: Any?
    private var completion: ((ScreenCaptureSelection?) -> Void)?
    private let controlsModel: CaptureControlsModel

    init(includeSystemAudio: Bool) {
        controlsModel = CaptureControlsModel(includeSystemAudio: includeSystemAudio)
        super.init()
    }

    func present(
        availableDisplayIDs: Set<CGDirectDisplayID>,
        completion: @escaping (ScreenCaptureSelection?) -> Void
    ) {
        self.completion = completion

        let screens = NSScreen.screens.filter {
            guard let id = Self.displayID(for: $0) else { return false }
            return availableDisplayIDs.contains(id)
        }
        guard !screens.isEmpty else {
            finish(with: nil)
            return
        }

        for screen in screens {
            guard let displayID = Self.displayID(for: screen) else { continue }
            let view = CaptureSelectionView(screen: screen, displayID: displayID)
            view.selectionDelegate = self

            let panel = CaptureOverlayPanel(
                // This initializer interprets the content origin relative to
                // the supplied screen. Passing screen.frame here applies a
                // secondary display's global origin twice.
                contentRect: CGRect(origin: .zero, size: screen.frame.size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.contentView = view
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.acceptsMouseMovedEvents = true
            panel.orderFrontRegardless()
            overlays.append(panel)
        }

        let mouseLocation = NSEvent.mouseLocation
        let initial = overlays
            .compactMap { $0.contentView as? CaptureSelectionView }
            .first(where: { $0.screen.frame.contains(mouseLocation) })
            ?? overlays.compactMap { $0.contentView as? CaptureSelectionView }.first

        if let initial {
            activate(initial)
            let bounds = initial.bounds.insetBy(dx: 80, dy: 70)
            let width = min(max(640, bounds.width * 0.72), bounds.width)
            let height = min(max(360, bounds.height * 0.66), bounds.height)
            initial.selectionRect = CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            ).integral
            selectionDidChange(in: initial)
        }

        showControls()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                self.confirm()
                return nil
            }
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
        activeView?.window?.makeKeyAndOrderFront(nil)
        controlsPanel?.orderFrontRegardless()
    }

    private func showControls() {
        let root = CaptureControlsView(
            model: controlsModel,
            confirm: { [weak self] in self?.confirm() },
            cancel: { [weak self] in self?.cancel() }
        )
        let panel = CaptureControlsPanel(
            contentRect: CGRect(x: 0, y: 0, width: 390, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: root)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        controlsPanel = panel
        positionControls()
        panel.orderFrontRegardless()
    }

    private func activate(_ view: CaptureSelectionView) {
        activeView = view
        for overlay in overlays {
            guard let candidate = overlay.contentView as? CaptureSelectionView else { continue }
            candidate.isActiveSelection = candidate === view
            if candidate !== view { candidate.selectionRect = nil }
        }
        view.window?.makeKey()
        positionControls()
    }

    private func selectionDidChange(in view: CaptureSelectionView) {
        guard view === activeView, let rect = view.selectionRect else { return }
        let pixelsWide = max(2, Int((rect.width * view.screen.backingScaleFactor).rounded()))
        let pixelsHigh = max(2, Int((rect.height * view.screen.backingScaleFactor).rounded()))
        controlsModel.sizeText = "\(pixelsWide) × \(pixelsHigh)"
        positionControls()
    }

    private func positionControls() {
        guard
            let panel = controlsPanel,
            let view = activeView,
            let rect = view.selectionRect
        else { return }

        let screen = view.screen.frame
        let globalRect = rect.offsetBy(dx: screen.minX, dy: screen.minY)
        let panelSize = panel.frame.size
        var x = globalRect.midX - panelSize.width / 2
        x = min(max(x, screen.minX + 12), screen.maxX - panelSize.width - 12)

        var y = globalRect.minY - panelSize.height - 14
        if y < screen.minY + 12 {
            y = min(globalRect.maxY + 14, screen.maxY - panelSize.height - 12)
        }
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func confirm() {
        guard
            let view = activeView,
            var rect = view.selectionRect,
            rect.width >= CaptureSelectionView.minimumSize.width,
            rect.height >= CaptureSelectionView.minimumSize.height
        else { return }

        rect = rect.integral.intersection(view.bounds)
        let sourceRect = CGRect(
            x: rect.minX,
            y: view.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let result = ScreenCaptureSelection(
            displayID: view.displayID,
            sourceRect: sourceRect,
            pointPixelScale: view.screen.backingScaleFactor,
            includeSystemAudio: controlsModel.includeSystemAudio
        )
        finish(with: result)
    }

    private func cancel() {
        finish(with: nil)
    }

    private func finish(with result: ScreenCaptureSelection?) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        controlsPanel?.orderOut(nil)
        controlsPanel = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        activeView = nil

        let callback = completion
        completion = nil
        callback?(result)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

extension CaptureSelectionCoordinator: CaptureSelectionViewDelegate {
    fileprivate func captureSelectionViewDidActivate(_ view: CaptureSelectionView) {
        activate(view)
    }

    fileprivate func captureSelectionViewDidChange(_ view: CaptureSelectionView) {
        selectionDidChange(in: view)
    }
}

@MainActor
private protocol CaptureSelectionViewDelegate: AnyObject {
    func captureSelectionViewDidActivate(_ view: CaptureSelectionView)
    func captureSelectionViewDidChange(_ view: CaptureSelectionView)
}

private final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CaptureControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CaptureControlsModel: ObservableObject {
    @Published var sizeText = ""
    @Published var includeSystemAudio: Bool

    init(includeSystemAudio: Bool) {
        self.includeSystemAudio = includeSystemAudio
    }
}

private struct CaptureControlsView: View {
    @ObservedObject var model: CaptureControlsModel
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.sizeText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Toggle("Speaker audio", isOn: $model.includeSystemAudio)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
            }

            Spacer(minLength: 4)

            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)

            Button(action: confirm) {
                Label("Record", systemImage: "record.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 14)
        .frame(width: 390, height: 64)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
private final class CaptureSelectionView: NSView {
    static let minimumSize = CGSize(width: 2, height: 2)
    private static let dragThreshold: CGFloat = 3
    private static let resizeOuterHitWidth: CGFloat = 18
    private static let resizeInnerHitWidth: CGFloat = 6
    private static let handleVisualSize: CGFloat = 12

    let screen: NSScreen
    let displayID: CGDirectDisplayID
    weak var selectionDelegate: CaptureSelectionViewDelegate?

    var selectionRect: CGRect? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var isActiveSelection = false {
        didSet { needsDisplay = true }
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum DragMode {
        case create(anchor: CGPoint, previous: CGRect?)
        case move(origin: CGPoint, initial: CGRect)
        case resize(handle: Handle, origin: CGPoint, initial: CGRect)
    }

    private var dragMode: DragMode?
    private var dragDidMove = false

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.screen = screen
        self.displayID = displayID
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return !isHidden && bounds.contains(localPoint) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        context.fill(bounds)

        guard isActiveSelection, let rect = selectionRect else {
            drawInactiveHint()
            return
        }

        let interior = rect.insetBy(dx: 1.5, dy: 1.5)
        context.clear(interior)

        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.96).setStroke()
        path.stroke()

        for handle in Handle.allCases {
            let handleRect = rectForHandle(handle, selection: rect)
            let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            handlePath.fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            handlePath.lineWidth = 1
            handlePath.stroke()
        }

        let size = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: size, attributes: attributes)
        let textSize = text.size()
        let badge = CGRect(
            x: rect.minX + 8,
            y: rect.maxY - textSize.height - 14,
            width: textSize.width + 12,
            height: textSize.height + 8
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 4))
    }

    private func drawInactiveHint() {
        let message = "Click and drag to select this display"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ]
        let text = NSAttributedString(string: message, attributes: attributes)
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        let point = constrained(convert(event.locationInWindow, from: nil))
        dragDidMove = false

        if !isActiveSelection {
            let previous = selectionRect
            selectionDelegate?.captureSelectionViewDidActivate(self)
            dragMode = .create(anchor: point, previous: previous)
            trackCurrentDrag()
            return
        }

        if let rect = selectionRect, let handle = handle(at: point, selection: rect) {
            dragMode = .resize(handle: handle, origin: point, initial: rect)
        } else if let rect = selectionRect, rect.contains(point) {
            dragMode = .move(origin: point, initial: rect)
        } else {
            dragMode = .create(anchor: point, previous: selectionRect)
        }
        trackCurrentDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = constrained(convert(event.locationInWindow, from: nil))
        updateCurrentDrag(to: point)
    }

    private func updateCurrentDrag(to point: CGPoint) {
        guard let dragMode else { return }

        switch dragMode {
        case .create(let anchor, _):
            guard hypot(point.x - anchor.x, point.y - anchor.y) >= Self.dragThreshold else {
                return
            }
            dragDidMove = true
            selectionRect = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            )
        case .move(let origin, let initial):
            guard hypot(point.x - origin.x, point.y - origin.y) >= Self.dragThreshold else {
                return
            }
            dragDidMove = true
            var moved = initial.offsetBy(dx: point.x - origin.x, dy: point.y - origin.y)
            if moved.minX < bounds.minX { moved.origin.x = bounds.minX }
            if moved.maxX > bounds.maxX { moved.origin.x = bounds.maxX - moved.width }
            if moved.minY < bounds.minY { moved.origin.y = bounds.minY }
            if moved.maxY > bounds.maxY { moved.origin.y = bounds.maxY - moved.height }
            selectionRect = moved
        case .resize(let handle, let origin, let initial):
            guard hypot(point.x - origin.x, point.y - origin.y) >= Self.dragThreshold else {
                return
            }
            dragDidMove = true
            selectionRect = resized(initial, handle: handle, delta: CGPoint(
                x: point.x - origin.x,
                y: point.y - origin.y
            ))
        }
        selectionDelegate?.captureSelectionViewDidChange(self)
    }

    override func mouseUp(with event: NSEvent) {
        let completedMode = dragMode
        defer {
            dragMode = nil
            dragDidMove = false
        }

        if !dragDidMove {
            let finalPoint = constrained(convert(event.locationInWindow, from: nil))
            updateCurrentDrag(to: finalPoint)
        }

        if !dragDidMove {
            if case let .create(_, previous)? = completedMode, previous == nil {
                selectionRect = defaultSelection(
                    centeredAt: constrained(convert(event.locationInWindow, from: nil))
                )
                selectionDelegate?.captureSelectionViewDidChange(self)
            }
            return
        }

        guard var rect = selectionRect else { return }

        if case let .move(_, initial)? = completedMode {
            rect.size = initial.size
            rect.origin.x = min(
                max(rect.origin.x.rounded(), bounds.minX),
                bounds.maxX - rect.width
            )
            rect.origin.y = min(
                max(rect.origin.y.rounded(), bounds.minY),
                bounds.maxY - rect.height
            )
            selectionRect = rect
        } else {
            selectionRect = enforcingMinimumSize(rect.integral)
        }
        selectionDelegate?.captureSelectionViewDidChange(self)
    }

    private func trackCurrentDrag() {
        guard let window else { return }
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self] event, stop in
            guard let self, let event else {
                stop.pointee = true
                return
            }

            switch event.type {
            case .leftMouseDragged:
                self.mouseDragged(with: event)
            case .leftMouseUp:
                self.mouseUp(with: event)
                stop.pointee = true
            default:
                break
            }
        }
    }

    override func resetCursorRects() {
        addValidCursorRect(bounds, cursor: .crosshair)
        guard
            isActiveSelection,
            let rect = selectionRect?.standardized,
            rect.width > 0,
            rect.height > 0
        else { return }

        addValidCursorRect(
            rect.insetBy(dx: Self.resizeInnerHitWidth, dy: Self.resizeInnerHitWidth),
            cursor: .openHand
        )

        let edgeHandles: [Handle] = [.top, .right, .bottom, .left]
        let cornerHandles: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        for handle in edgeHandles + cornerHandles {
            addValidCursorRect(cursorRect(for: handle, selection: rect), cursor: cursor(for: handle))
        }
    }

    private func addValidCursorRect(_ rect: CGRect, cursor: NSCursor) {
        let clipped = rect.standardized.intersection(bounds)
        guard
            !clipped.isNull,
            !clipped.isEmpty,
            clipped.width.isFinite,
            clipped.height.isFinite,
            clipped.width > 0,
            clipped.height > 0
        else { return }
        addCursorRect(clipped, cursor: cursor)
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func enforcingMinimumSize(_ rect: CGRect) -> CGRect {
        var adjusted = rect.standardized.intersection(bounds)
        adjusted.size.width = min(
            max(adjusted.width, Self.minimumSize.width),
            bounds.width
        )
        adjusted.size.height = min(
            max(adjusted.height, Self.minimumSize.height),
            bounds.height
        )
        adjusted.origin.x = min(
            max(adjusted.origin.x, bounds.minX),
            bounds.maxX - adjusted.width
        )
        adjusted.origin.y = min(
            max(adjusted.origin.y, bounds.minY),
            bounds.maxY - adjusted.height
        )
        return adjusted
    }

    private func handle(at point: CGPoint, selection: CGRect) -> Handle? {
        let rect = selection.standardized
        let outer = Self.resizeOuterHitWidth
        let inner = Self.resizeInnerHitWidth
        guard rect.insetBy(dx: -outer, dy: -outer).contains(point) else { return nil }

        let nearLeft = point.x >= rect.minX - outer && point.x <= rect.minX + inner
        let nearRight = point.x >= rect.maxX - inner && point.x <= rect.maxX + outer
        let nearBottom = point.y >= rect.minY - outer && point.y <= rect.minY + inner
        let nearTop = point.y >= rect.maxY - inner && point.y <= rect.maxY + outer

        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearTop { return .top }
        if nearRight { return .right }
        if nearBottom { return .bottom }
        if nearLeft { return .left }
        return nil
    }

    private func rectForHandle(_ handle: Handle, selection: CGRect) -> CGRect {
        let size = Self.handleVisualSize
        let center: CGPoint
        switch handle {
        case .topLeft: center = CGPoint(x: selection.minX, y: selection.maxY)
        case .top: center = CGPoint(x: selection.midX, y: selection.maxY)
        case .topRight: center = CGPoint(x: selection.maxX, y: selection.maxY)
        case .right: center = CGPoint(x: selection.maxX, y: selection.midY)
        case .bottomRight: center = CGPoint(x: selection.maxX, y: selection.minY)
        case .bottom: center = CGPoint(x: selection.midX, y: selection.minY)
        case .bottomLeft: center = CGPoint(x: selection.minX, y: selection.minY)
        case .left: center = CGPoint(x: selection.minX, y: selection.midY)
        }
        return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    private func cursorRect(for handle: Handle, selection: CGRect) -> CGRect {
        let outer = Self.resizeOuterHitWidth
        let inner = Self.resizeInnerHitWidth
        let edgeSpan = outer + inner

        switch handle {
        case .topLeft:
            return CGRect(
                x: selection.minX - outer,
                y: selection.maxY - inner,
                width: edgeSpan,
                height: edgeSpan
            )
        case .topRight:
            return CGRect(
                x: selection.maxX - inner,
                y: selection.maxY - inner,
                width: edgeSpan,
                height: edgeSpan
            )
        case .bottomRight:
            return CGRect(
                x: selection.maxX - inner,
                y: selection.minY - outer,
                width: edgeSpan,
                height: edgeSpan
            )
        case .bottomLeft:
            return CGRect(
                x: selection.minX - outer,
                y: selection.minY - outer,
                width: edgeSpan,
                height: edgeSpan
            )
        case .top:
            return CGRect(
                x: selection.minX + inner,
                y: selection.maxY - inner,
                width: max(0, selection.width - inner * 2),
                height: edgeSpan
            )
        case .right:
            return CGRect(
                x: selection.maxX - inner,
                y: selection.minY + inner,
                width: edgeSpan,
                height: max(0, selection.height - inner * 2)
            )
        case .bottom:
            return CGRect(
                x: selection.minX + inner,
                y: selection.minY - outer,
                width: max(0, selection.width - inner * 2),
                height: edgeSpan
            )
        case .left:
            return CGRect(
                x: selection.minX - outer,
                y: selection.minY + inner,
                width: edgeSpan,
                height: max(0, selection.height - inner * 2)
            )
        }
    }

    private func defaultSelection(centeredAt point: CGPoint) -> CGRect {
        let size = CGSize(
            width: min(640, max(Self.minimumSize.width, bounds.width - 24)),
            height: min(360, max(Self.minimumSize.height, bounds.height - 24))
        )
        var rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect.integral
    }

    private func cursor(for handle: Handle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return .crosshair
        case .topRight, .bottomLeft: return .crosshair
        }
    }

    private func resized(_ initial: CGRect, handle: Handle, delta: CGPoint) -> CGRect {
        var minX = initial.minX
        var maxX = initial.maxX
        var minY = initial.minY
        var maxY = initial.maxY

        if [.topLeft, .bottomLeft, .left].contains(handle) {
            minX = min(max(initial.minX + delta.x, bounds.minX), maxX - Self.minimumSize.width)
        }
        if [.topRight, .bottomRight, .right].contains(handle) {
            maxX = max(min(initial.maxX + delta.x, bounds.maxX), minX + Self.minimumSize.width)
        }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) {
            minY = min(max(initial.minY + delta.y, bounds.minY), maxY - Self.minimumSize.height)
        }
        if [.topLeft, .top, .topRight].contains(handle) {
            maxY = max(min(initial.maxY + delta.y, bounds.maxY), minY + Self.minimumSize.height)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
