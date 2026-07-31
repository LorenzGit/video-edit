import SwiftUI
import AppKit

struct TimelineView: View {
    @EnvironmentObject var vm: EditorViewModel
    @StateObject private var scrollController = TimelineScrollController()
    @State private var timelineDrag: TimelineDragState?
    @State private var dragContext: TimelineDragContext?
    @State private var trimPreview: TimelineTrimPreview?

    private let rulerHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            GeometryReader { geo in
                Group {
                    if vm.totalDuration <= 0 {
                        emptyTimeline
                    } else {
                        timelineBody(
                            width: geo.size.width,
                            height: geo.size.height,
                            viewportFrame: geo.frame(in: .global)
                        )
                    }
                }
                .onChange(of: geo.size.width, initial: true) { _, w in vm.timelineWidth = w }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(height: 150)
        .background(Theme.panel.opacity(0.45))
        .onDisappear {
            stopAutoScroll()
        }
    }

    private var displayedChunks: [Chunk] {
        guard let trimPreview else { return vm.chunks }
        return vm.chunks.map { chunk in
            chunk.id == trimPreview.chunkID ? trimPreview.preview : chunk
        }
    }

    private func fitScale(_ width: CGFloat, total: Double) -> Double {
        Double(width) / max(total, 0.0001)
    }

    // MARK: Body (ruler + clips + playhead, horizontally scrollable)

    private func timelineBody(width: CGFloat, height: CGFloat, viewportFrame: CGRect) -> some View {
        let chunks = displayedChunks
        let total = max(chunks.reduce(0) { $0 + $1.outputDuration }, 0.0001)
        let scale = vm.pps ?? fitScale(width, total: total)
        let contentWidth = CGFloat(total * scale)
        let bodyHeight = height
        let clipHeight = max(40, height - rulerHeight - 6)
        let playheadX = min(max(CGFloat(vm.currentTime) * CGFloat(scale), 0), contentWidth)
        let anchorStep = max(1, Int((total / 400).rounded(.up)))

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 6) {
                        RulerView(scale: CGFloat(scale), total: total, width: contentWidth)
                            .frame(width: contentWidth, height: rulerHeight)
                            .contentShape(Rectangle())
                            .gesture(scrubGesture(scale: scale))
                        chunkRow(
                            chunks: chunks,
                            scale: CGFloat(scale),
                            viewportFrame: viewportFrame
                        )
                            .frame(width: contentWidth, height: clipHeight)
                    }

                    // Invisible scroll anchors so playback can keep the playhead in view.
                    ForEach(Array(stride(from: 0, through: Int(total), by: anchorStep)), id: \.self) { sec in
                        Color.clear
                            .frame(width: 1, height: 1)
                            .position(x: CGFloat(Double(sec) * scale), y: 1)
                            .id(sec)
                    }

                    PlayheadView()
                        .frame(width: 12, height: bodyHeight)
                        .offset(x: playheadX - 6)
                        .allowsHitTesting(false)

                    TimelineScrollViewAccessor(controller: scrollController)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
                .frame(width: contentWidth, height: bodyHeight)
            }
            .frame(height: bodyHeight)
            .onChange(of: vm.currentTime) { _, time in
                guard vm.isPlaying, vm.pps != nil, !vm.isScrubbing else { return }
                let snapped = (Int(time) / anchorStep) * anchorStep
                proxy.scrollTo(snapped, anchor: .center)
            }
        }
    }

    private func chunkRow(
        chunks: [Chunk],
        scale: CGFloat,
        viewportFrame: CGRect
    ) -> some View {
        let placements = timelinePlacements(chunks: chunks, scale: scale)
        return ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.clearSelection() }
            HStack(spacing: 0) {
                ForEach(placements) { placement in
                    ChunkView(
                        chunk: placement.chunk,
                        filmstripChunk: trimPreview?.chunkID == placement.id
                            ? (trimPreview?.original ?? placement.chunk)
                            : placement.chunk,
                        slotWidth: placement.width,
                        dragState: timelineDrag,
                        onDragChanged: { translation, pointerGlobalX in
                            updateTimelineDrag(
                                placement: placement,
                                translation: translation,
                                placements: placements,
                                pointerGlobalX: pointerGlobalX,
                                viewportFrame: viewportFrame
                            )
                        },
                        onDragEnded: {
                            finishTimelineDrag()
                        },
                        onTrimChanged: { edge, translation in
                            updateTrimPreview(
                                chunk: placement.chunk,
                                edge: edge,
                                translation: translation,
                                scale: scale
                            )
                        },
                        onTrimEnded: { edge, translation in
                            finishTrimPreview(
                                chunk: placement.chunk,
                                edge: edge,
                                translation: translation,
                                scale: scale
                            )
                        },
                        onTrimRestore: { edge in
                            restoreTrim(
                                chunk: placement.chunk,
                                edge: edge,
                                scale: scale
                            )
                        }
                    )
                }
            }
        }
    }

    private func timelinePlacements(chunks: [Chunk], scale: CGFloat) -> [TimelinePlacement] {
        var cursor: CGFloat = 0
        return chunks.map { chunk in
            let width = max(2, CGFloat(chunk.outputDuration) * scale)
            defer { cursor += width }
            return TimelinePlacement(chunk: chunk, start: cursor, width: width)
        }
    }

    private func updateTrimPreview(
        chunk: Chunk,
        edge: EditorViewModel.TrimEdge,
        translation: CGFloat,
        scale: CGFloat
    ) {
        var session: TimelineTrimPreview
        if let current = trimPreview,
           current.chunkID == chunk.id,
           current.edge == edge {
            session = current
        } else {
            stopAutoScroll()
            timelineDrag = nil
            dragContext = nil

            let wasFitZoom = vm.pps == nil
            if wasFitZoom {
                // Trimming switches from fit-to-window to the exact scale the
                // user grabbed. Keeping it after release prevents snap-back.
                vm.pps = Double(scale)
            }
            vm.beginTrimPreview(chunk.id)
            session = TimelineTrimPreview(
                chunkID: chunk.id,
                edge: edge,
                original: chunk,
                preview: chunk,
                scale: scale,
                wasFitZoom: wasFitZoom
            )
        }

        let sourceDelta = Double(translation / max(session.scale, 0.0001))
            * session.original.speed
        session.preview = vm.trimPreview(
            from: session.original,
            edge: edge,
            sourceDelta: sourceDelta
        )
        trimPreview = session
    }

    private func finishTrimPreview(
        chunk: Chunk,
        edge: EditorViewModel.TrimEdge,
        translation: CGFloat,
        scale: CGFloat
    ) {
        updateTrimPreview(
            chunk: chunk,
            edge: edge,
            translation: translation,
            scale: scale
        )
        guard let session = trimPreview else { return }

        let changed = vm.commitTrimPreview(session.preview)
        trimPreview = nil
        if !changed, session.wasFitZoom {
            vm.pps = nil
        }
    }

    private func restoreTrim(
        chunk: Chunk,
        edge: EditorViewModel.TrimEdge,
        scale: CGFloat
    ) {
        if vm.pps == nil {
            vm.pps = Double(scale)
        }
        vm.restoreTrim(chunk.id, edge: edge)
    }

    private func updateTimelineDrag(
        placement: TimelinePlacement,
        translation: CGFloat,
        placements: [TimelinePlacement],
        pointerGlobalX: CGFloat,
        viewportFrame: CGRect
    ) {
        let isNewDrag = dragContext?.placement.id != placement.id
        if isNewDrag {
            vm.select(placement.id, additive: false)
        }

        let context = TimelineDragContext(
            placement: placement,
            placements: placements,
            gestureTranslation: translation,
            initialScrollOffset: isNewDrag
                ? scrollController.horizontalOffset
                : (dragContext?.initialScrollOffset ?? scrollController.horizontalOffset)
        )
        dragContext = context
        refreshTimelineDrag(using: context)
        updateAutoScroll(pointerGlobalX: pointerGlobalX, viewportFrame: viewportFrame)
    }

    private func refreshTimelineDrag(using context: TimelineDragContext) {
        let scrollDelta = scrollController.horizontalOffset - context.initialScrollOffset
        let adjustedTranslation = context.gestureTranslation + scrollDelta
        let pointerX = context.placement.start + context.placement.width / 2 + adjustedTranslation
        let target = context.placements.first(where: { pointerX < $0.start + $0.width })
            ?? context.placements.last
        guard let target else { return }
        let placeAfter = pointerX >= target.start + target.width / 2

        timelineDrag = TimelineDragState(
            id: context.placement.id,
            translation: adjustedTranslation,
            targetID: target.id,
            placeAfter: placeAfter
        )
    }

    private func finishTimelineDrag() {
        stopAutoScroll()
        dragContext = nil
        guard let drag = timelineDrag else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            _ = vm.moveChunk(drag.id, relativeTo: drag.targetID, after: drag.placeAfter)
            timelineDrag = nil
        }
    }

    private func updateAutoScroll(pointerGlobalX: CGFloat, viewportFrame: CGRect) {
        let threshold = min(72, viewportFrame.width * 0.16)
        let leftDistance = pointerGlobalX - viewportFrame.minX
        let rightDistance = viewportFrame.maxX - pointerGlobalX
        let velocity: CGFloat

        if leftDistance < threshold {
            let intensity = min(1, max(0, (threshold - leftDistance) / threshold))
            velocity = -(3 + 13 * intensity)
        } else if rightDistance < threshold {
            let intensity = min(1, max(0, (threshold - rightDistance) / threshold))
            velocity = 3 + 13 * intensity
        } else {
            velocity = 0
        }

        if velocity == 0 {
            scrollController.stopAutoScroll()
            return
        }

        if !scrollController.isAutoScrolling {
            let initialMovement = scrollController.scrollHorizontally(by: velocity)
            guard abs(initialMovement) > 0.01 else { return }
            if let dragContext {
                refreshTimelineDrag(using: dragContext)
            }
        }

        scrollController.startAutoScroll(velocity: velocity) {
            if let dragContext {
                refreshTimelineDrag(using: dragContext)
            }
        }
    }

    private func stopAutoScroll() {
        scrollController.stopAutoScroll()
    }

    private func scrubGesture(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in vm.scrub(to: Double(value.location.x) / max(scale, 0.0001)) }
            .onEnded { _ in vm.endScrub() }
    }

    private var emptyTimeline: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textTertiary)
            Text("All clips removed — press ⌘Z to undo")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TimelineDragContext {
    let placement: TimelinePlacement
    let placements: [TimelinePlacement]
    let gestureTranslation: CGFloat
    let initialScrollOffset: CGFloat
}

private struct TimelineTrimPreview {
    let chunkID: UUID
    let edge: EditorViewModel.TrimEdge
    let original: Chunk
    var preview: Chunk
    let scale: CGFloat
    let wasFitZoom: Bool
}

@MainActor
private final class TimelineScrollController: ObservableObject {
    weak var scrollView: NSScrollView?
    private var autoScrollTimer: Timer?
    private var autoScrollVelocity: CGFloat = 0
    private var onAutoScroll: (() -> Void)?

    var isAutoScrolling: Bool {
        autoScrollTimer != nil
    }

    var horizontalOffset: CGFloat {
        scrollView?.contentView.bounds.origin.x ?? 0
    }

    func attach(from view: NSView) {
        if let enclosingScrollView = view.enclosingScrollView {
            scrollView = enclosingScrollView
            return
        }

        var candidate = view.superview
        while let current = candidate {
            if let enclosingScrollView = current as? NSScrollView {
                scrollView = enclosingScrollView
                return
            }
            candidate = current.superview
        }
    }

    @discardableResult
    func scrollHorizontally(by delta: CGFloat) -> CGFloat {
        guard
            let scrollView,
            let documentView = scrollView.documentView
        else { return 0 }

        let clipView = scrollView.contentView
        let oldX = clipView.bounds.origin.x
        let maxX = max(0, documentView.frame.width - clipView.bounds.width)
        let newX = min(max(0, oldX + delta), maxX)
        guard abs(newX - oldX) > 0.01 else { return 0 }

        clipView.scroll(to: NSPoint(x: newX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        return newX - oldX
    }

    func startAutoScroll(velocity: CGFloat, onScroll: @escaping () -> Void) {
        autoScrollVelocity = velocity
        onAutoScroll = onScroll
        guard autoScrollTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let moved = self.scrollHorizontally(by: self.autoScrollVelocity)
                guard abs(moved) > 0.01 else {
                    self.stopAutoScroll()
                    return
                }
                self.onAutoScroll?()
            }
        }
        timer.tolerance = 1.0 / 240.0
        autoScrollTimer = timer

        // A normal main-run-loop timer pauses while AppKit is tracking a held
        // mouse drag. Common modes keep edge scrolling alive until mouse-up.
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollVelocity = 0
        onAutoScroll = nil
    }
}

@MainActor
private struct TimelineScrollViewAccessor: NSViewRepresentable {
    let controller: TimelineScrollController

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            controller.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            controller.attach(from: nsView)
        }
    }
}

// MARK: - One clip on the timeline

private struct ChunkView: View {
    @EnvironmentObject var vm: EditorViewModel
    let chunk: Chunk
    let filmstripChunk: Chunk
    let slotWidth: CGFloat
    let dragState: TimelineDragState?
    let onDragChanged: (CGFloat, CGFloat) -> Void
    let onDragEnded: () -> Void
    let onTrimChanged: (EditorViewModel.TrimEdge, CGFloat) -> Void
    let onTrimEnded: (EditorViewModel.TrimEdge, CGFloat) -> Void
    let onTrimRestore: (EditorViewModel.TrimEdge) -> Void

    private var isSelected: Bool { vm.selection.contains(chunk.id) }
    private var visibleWidth: CGFloat { max(2, slotWidth - 4) }
    private var isDragging: Bool { dragState?.id == chunk.id }
    private var dropEdge: TimelineDropEdge? {
        guard
            let dragState,
            dragState.id != chunk.id,
            dragState.targetID == chunk.id
        else { return nil }
        return dragState.placeAfter ? .trailing : .leading
    }

    var body: some View {
        FilmstripCard(
            chunk: filmstripChunk,
            displayDuration: chunk.outputDuration,
            width: visibleWidth,
            isSelected: isSelected
        )
            .frame(width: visibleWidth)
            .frame(width: max(2, slotWidth))
            .contentShape(Rectangle())
            .overlay {
                if isSelected {
                    trimHandles
                }
            }
            .overlay {
                dropIndicator
            }
            .offset(
                x: isDragging ? (dragState?.translation ?? 0) : 0,
                y: isDragging ? -8 : 0
            )
            .rotationEffect(.degrees(isDragging ? -1.8 : 0))
            .scaleEffect(isDragging ? 1.035 : (dropEdge == nil ? 1 : 0.975))
            .shadow(
                color: isDragging ? Theme.accent.opacity(0.52) : .clear,
                radius: isDragging ? 15 : 0,
                y: isDragging ? 8 : 0
            )
            .zIndex(isDragging ? 100 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isDragging)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: dropEdge)
            .onTapGesture {
                let additive = NSEvent.modifierFlags.contains(.command)
                vm.select(chunk.id, additive: additive)
            }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        onDragChanged(value.translation.width, value.location.x)
                    }
                    .onEnded { _ in
                        onDragEnded()
                    }
            )
    }

    private var trimHandles: some View {
        HStack(spacing: 0) {
            if vm.canRestoreTrim(chunk.id, edge: .leading) {
                TrimHandle(
                    edge: .leading,
                    onDragChanged: { onTrimChanged(.leading, $0) },
                    onDragEnded: { onTrimEnded(.leading, $0) },
                    onRestore: { onTrimRestore(.leading) }
                )
            } else {
                Color.clear
                    .frame(width: 16)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 0)

            if vm.canRestoreTrim(chunk.id, edge: .trailing) {
                TrimHandle(
                    edge: .trailing,
                    onDragChanged: { onTrimChanged(.trailing, $0) },
                    onDragEnded: { onTrimEnded(.trailing, $0) },
                    onRestore: { onTrimRestore(.trailing) }
                )
            } else {
                Color.clear
                    .frame(width: 16)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private var dropIndicator: some View {
        if let dropEdge {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 4)
                        .frame(maxHeight: .infinity)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                }
                .shadow(color: Theme.accent.opacity(0.9), radius: 6)
                .position(
                    x: dropEdge == .leading ? 3 : geo.size.width - 3,
                    y: geo.size.height / 2
                )
            }
            .padding(.vertical, -4)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.75).combined(with: .opacity))
        }
    }
}

private struct TimelinePlacement: Identifiable {
    let chunk: Chunk
    let start: CGFloat
    let width: CGFloat
    var id: UUID { chunk.id }
}

private struct TimelineDragState {
    let id: UUID
    let translation: CGFloat
    let targetID: UUID
    let placeAfter: Bool
}

private enum TimelineDropEdge: Equatable {
    case leading
    case trailing
}

private struct TrimHandle: View {
    let edge: EditorViewModel.TrimEdge
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    let onRestore: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isDragging ? Color.white : Theme.speedTint)
                .frame(width: 7)
                .padding(.vertical, 4)
                .shadow(
                    color: Theme.speedTint.opacity(0.7),
                    radius: isDragging ? 7 : 3
                )

            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 3, height: 1)
                }
            }
        }
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .brightness(isHovering ? 0.08 : 0)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(helpText)
        .onTapGesture(count: 2) {
            onRestore()
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    onDragChanged(value.location.x - value.startLocation.x)
                }
                .onEnded { value in
                    onDragEnded(value.location.x - value.startLocation.x)
                    isDragging = false
                }
        )
        .accessibilityLabel(edge == .leading ? "Adjust clip beginning" : "Adjust clip end")
    }

    private var helpText: String {
        let boundary = edge == .leading ? "beginning" : "end"
        return "Drag either direction to adjust the clip's \(boundary). Double-click to restore it completely."
    }
}

private struct FilmstripCard: View {
    @EnvironmentObject var vm: EditorViewModel
    let chunk: Chunk
    let displayDuration: Double
    let width: CGFloat
    let isSelected: Bool

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let aspect = vm.aspect(sourceID: chunk.sourceID)
            let tileW = max(30, h * aspect)
            let tiles = max(1, Int((width / tileW).rounded(.up)))
            ZStack {
                Theme.clip
                HStack(spacing: 0) {
                    ForEach(0..<tiles, id: \.self) { i in
                        let sourceTime = chunk.start
                            + (Double(i) + 0.5) / Double(tiles) * chunk.sourceDuration
                        thumb(at: sourceTime, w: width / CGFloat(tiles), sourceID: chunk.sourceID)
                    }
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.5)],
                    startPoint: .center, endPoint: .bottom
                )
                badges
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Theme.accent : Theme.clipBorder,
                        lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: isSelected ? Theme.accent.opacity(0.35) : .clear, radius: 6)
    }

    @ViewBuilder
    private func thumb(at sourceTime: Double, w: CGFloat, sourceID: UUID) -> some View {
        ZStack {
            Theme.clip
            if let image = vm.thumbnail(sourceID: sourceID, near: sourceTime) {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: w)
        .clipped()
    }

    private var badges: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                if chunk.speed != 1.0 {
                    Text(speedLabel(chunk.speed))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.speedTint))
                }
                Spacer()
                if width > 54 {
                    Text(timecode(displayDuration))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
    }
}

// MARK: - Playhead

private struct PlayheadView: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white)
                .frame(width: 12, height: 14)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            Rectangle()
                .fill(Color.white)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Ruler

private struct RulerView: View {
    let scale: CGFloat
    let total: Double
    let width: CGFloat

    var body: some View {
        let step = niceTimeStep(scale: scale)
        let count = step > 0 ? Int(total / step) : 0
        ZStack(alignment: .topLeading) {
            ForEach(0...max(0, count), id: \.self) { i in
                let t = Double(i) * step
                let x = CGFloat(t) * scale
                if x <= width - 4 {
                    VStack(alignment: .leading, spacing: 3) {
                        Rectangle().fill(Theme.strokeHi).frame(width: 1, height: 6)
                        Text(timecode(t, showCentis: step < 1))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize()
                    }
                    .offset(x: x)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Picks a human-friendly time step so ticks land roughly every ~80pt.
private func niceTimeStep(scale: CGFloat) -> Double {
    let targetSeconds = 80.0 / Double(max(scale, 0.0001))
    let candidates: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
    for c in candidates where c >= targetSeconds { return c }
    return candidates.last ?? 3600
}
