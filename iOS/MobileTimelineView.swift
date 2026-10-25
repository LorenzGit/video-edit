import SwiftUI
import UIKit

/// A single time axis: scrolling and playback move the filmstrip beneath the
/// fixed playhead when zoomed. Fit shows the complete edit with a playhead
/// that moves across it. Clip widths always represent edited duration exactly.
struct MobileTimelineView: UIViewRepresentable {
    @ObservedObject var editor: EditorViewModel
    @Binding var pointsPerSecond: Double
    @Binding var fitsTimeline: Bool
    var showsAudio: Bool

    static func fittedScale(duration: Double, width: CGFloat) -> Double {
        max(0.000001, max(1, width - 32) / max(0.000001, duration))
    }
    var compact: Bool

    func makeUIView(context: Context) -> TimelineView {
        let view = TimelineView()
        view.update(editor: editor, scale: pointsPerSecond, fitted: fitsTimeline, compact: compact, showsAudio: showsAudio,
                    onScale: { pointsPerSecond = $0 }, onFitChange: { fitsTimeline = $0 })
        return view
    }

    func updateUIView(_ view: TimelineView, context: Context) {
        view.update(editor: editor, scale: pointsPerSecond, fitted: fitsTimeline, compact: compact, showsAudio: showsAudio,
                    onScale: { pointsPerSecond = $0 }, onFitChange: { fitsTimeline = $0 })
    }

    final class TimelineView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let scrollView = UIScrollView()
        private let viewport = TimelineViewport()
        private weak var editor: EditorViewModel?
        private var scale: Double = 44
        private var compact = false
        private var showsAudio = false
        private var fitted = false
        private var onScale: ((Double) -> Void)?
        private var onFitChange: ((Bool) -> Void)?
        private var updatingOffset = false
        private var pinching = false
        private var pinchScale: Double = 44
        private var pinchTime: Double = 0
        private var trim: TrimGesture?
        private var reorder: ReorderGesture?
        private var reorderTicker: CADisplayLink?
        private let reorderFeedback = UISelectionFeedbackGenerator()
        private lazy var trimPan = UIPanGestureRecognizer(target: self, action: #selector(trimDragged))
        private lazy var fitPan = UIPanGestureRecognizer(target: self, action: #selector(fitScrubbed))
        private lazy var reorderPress = UILongPressGestureRecognizer(target: self, action: #selector(clipHeld))

        private struct ReorderGesture {
            let original: [Chunk]
            let chunk: Chunk
            let originalIndex: Int
            let liftedWidth: CGFloat
            let grabOffset: CGFloat
            var destination: Int
            var point: CGPoint

            var preview: [Chunk] {
                var clips = original
                clips.remove(at: originalIndex)
                clips.insert(chunk, at: destination)
                return clips
            }
        }

        private final class ReorderTicker: NSObject {
            weak var owner: TimelineView?
            init(owner: TimelineView) { self.owner = owner }
            @objc func tick(_ link: CADisplayLink) { owner?.scrollWhileReordering(link) }
        }

        private struct TrimGesture {
            let original: Chunk
            let edge: EditorViewModel.TrimEdge
            let timelineStart: Double
            var preview: Chunk
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            scrollView.delegate = self
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.decelerationRate = .fast
            scrollView.alwaysBounceVertical = false
            scrollView.isDirectionalLockEnabled = true
            scrollView.scrollsToTop = false
            scrollView.accessibilityIdentifier = "timelineScrollView"
            scrollView.isAccessibilityElement = true
            scrollView.accessibilityLabel = "Timeline filmstrip"
            isAccessibilityElement = false
            addSubview(scrollView)
            viewport.isUserInteractionEnabled = false
            viewport.backgroundColor = .clear
            addSubview(viewport)
            viewport.owner = self
            viewport.accessibilityElementsHidden = true

            trimPan.maximumNumberOfTouches = 1
            scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
            trimPan.delegate = self
            addGestureRecognizer(trimPan)
            scrollView.panGestureRecognizer.require(toFail: trimPan)
            reorderPress.minimumPressDuration = 0.35
            reorderPress.allowableMovement = 10
            reorderPress.delegate = self
            addGestureRecognizer(reorderPress)
            scrollView.panGestureRecognizer.require(toFail: reorderPress)
            fitPan.delegate = self
            fitPan.maximumNumberOfTouches = 1
            fitPan.require(toFail: trimPan)
            fitPan.require(toFail: reorderPress)
            addGestureRecognizer(fitPan)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.require(toFail: trimPan)
            tap.require(toFail: reorderPress)
            scrollView.addGestureRecognizer(tap)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
            pinch.delegate = self
            addGestureRecognizer(pinch)
            clipsToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil { finishReorder(commit: false) }
            super.willMove(toWindow: newWindow)
        }

        func update(editor: EditorViewModel, scale: Double, fitted: Bool, compact: Bool, showsAudio: Bool,
                    onScale: @escaping (Double) -> Void, onFitChange: @escaping (Bool) -> Void) {
            self.editor = editor
            self.onScale = onScale
            self.onFitChange = onFitChange
            self.fitted = fitted
            self.scale = fitted ? MobileTimelineView.fittedScale(duration: editor.totalDuration, width: bounds.width)
                                : max(0.001, scale)
            self.compact = compact
            self.showsAudio = showsAudio
            if let reorder, reorder.original != editor.chunks { finishReorder(commit: false) }
            configureInsets()
            updateContentSize()
            if !scrollView.isDragging && !scrollView.isDecelerating && !pinching && trim == nil && reorder == nil {
                setTime(editor.currentTime)
            }
            viewport.setNeedsDisplay()
            accessibilityElements = accessibilityItems()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updatingOffset = true
            if scrollView.bounds.size != bounds.size { finishReorder(commit: false) }
            scrollView.frame = bounds
            viewport.frame = bounds
            if fitted, let editor {
                scale = MobileTimelineView.fittedScale(duration: editor.totalDuration, width: bounds.width)
            }
            configureInsets()
            updateContentSize()
            if let editor, !scrollView.isDragging, !scrollView.isDecelerating, trim == nil, reorder == nil, !pinching {
                setTime(editor.currentTime)
            }
            updatingOffset = false
            viewport.setNeedsDisplay()
            accessibilityElements = accessibilityItems()
        }

        private func configureInsets() {
            let inset = fitted ? 16 : bounds.width / 2
            let previous = updatingOffset
            updatingOffset = true
            let insets = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            if scrollView.contentInset != insets { scrollView.contentInset = insets }
            scrollView.isScrollEnabled = !fitted
            scrollView.bounces = !fitted
            updatingOffset = previous
        }

        private func updateContentSize() {
            guard let editor else { return }
            let size = CGSize(width: max(1, editor.totalDuration * scale), height: bounds.height)
            if scrollView.contentSize != size {
                let previous = updatingOffset
                updatingOffset = true
                scrollView.contentSize = size
                updatingOffset = previous
            }
        }

        private func setTime(_ time: Double) {
            let offset = fitted ? -16 : time * scale - bounds.width / 2
            guard abs(scrollView.contentOffset.x - offset) > 0.1 else { return }
            let previous = updatingOffset
            updatingOffset = true
            scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
            updatingOffset = previous
        }

        private func time(at x: CGFloat) -> Double {
            max(0, min(editor?.totalDuration ?? 0, (x + scrollView.contentOffset.x) / scale))
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { editor?.beginScrub() }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !updatingOffset else { return }
            if trim == nil && reorder == nil && !pinching && (scrollView.isDragging || scrollView.isDecelerating) {
                editor?.scrub(to: time(at: bounds.midX))
            }
            viewport.setNeedsDisplay()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishScrub() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrub() }

        private func finishScrub() {
            guard trim == nil, reorder == nil, !pinching else { return }
            editor?.endScrub()
            viewport.setNeedsDisplay()
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let editor else { return }
            let point = gesture.location(in: self)
            if showsAudio {
                let sourceAudio = editor.mobileVideoAudioSegments
                let addedAudio = editor.mobileAddedAudioSegments
                for (segments, y) in [(sourceAudio, audioTop), (addedAudio, addedAudioTop)] {
                    if let hit = segments.first(where: { audioFrame($0, y: y).contains(point) && $0.hasAudio }) {
                        editor.selectMobileAudio(hit.target)
                        UISelectionFeedbackGenerator().selectionChanged()
                        return
                    }
                }
            }
            guard point.y >= trackTop, point.y <= trackTop + trackHeight else { return }
            let hitTime = (point.x + scrollView.contentOffset.x) / scale
            var start = 0.0
            for chunk in editor.chunks {
                if hitTime >= start, hitTime <= start + chunk.outputDuration {
                    // Selecting a clip never moves the playhead to its beginning.
                    editor.beginTrimPreview(chunk.id)
                    UISelectionFeedbackGenerator().selectionChanged()
                    viewport.setNeedsDisplay()
                    return
                }
                start += chunk.outputDuration
            }
            editor.clearSelection()
            viewport.setNeedsDisplay()
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === reorderPress {
                let point = gestureRecognizer.location(in: self)
                return (editor?.chunks.count ?? 0) > 1 && !pinching && trim == nil
                    && chunk(at: point) != nil && handle(at: point) == nil
            }
            if gestureRecognizer === fitPan {
                return fitted && handle(at: gestureRecognizer.location(in: self)) == nil
            }
            guard gestureRecognizer === trimPan else { return true }
            return handle(at: gestureRecognizer.location(in: self)) != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer !== reorderPress, other !== reorderPress else { return false }
            return gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
        }

        private func chunk(at point: CGPoint) -> Chunk? {
            editor?.chunks.first { clipFrame($0).contains(point) }
        }

        @objc private func clipHeld(_ gesture: UILongPressGestureRecognizer) {
            guard let editor else { return }
            let point = gesture.location(in: self)
            switch gesture.state {
            case .began:
                guard let chunk = chunk(at: point),
                      let index = editor.chunks.firstIndex(where: { $0.id == chunk.id }) else { return }
                let visible = clipFrame(chunk).intersection(bounds)
                let width = min(160, max(48, visible.width))
                reorder = ReorderGesture(original: editor.chunks, chunk: chunk, originalIndex: index,
                                         liftedWidth: width, grabOffset: visible.midX - point.x,
                                         destination: index, point: point)
                editor.beginTrimPreview(chunk.id)
                editor.beginScrub()
                // Stop any outstanding deceleration without moving the playhead.
                scrollView.setContentOffset(scrollView.contentOffset, animated: false)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                reorderFeedback.prepare()
                let ticker = CADisplayLink(target: ReorderTicker(owner: self), selector: #selector(ReorderTicker.tick(_:)))
                ticker.add(to: .main, forMode: .common)
                reorderTicker = ticker
                viewport.setNeedsDisplay()
            case .changed:
                reorder?.point = point
                updateReorderDestination()
            case .ended:
                reorder?.point = point
                updateReorderDestination()
                finishReorder(commit: true)
            case .cancelled, .failed: finishReorder(commit: false)
            default: break
            }
        }

        private func updateReorderDestination() {
            guard var state = reorder else { return }
            let clips = state.preview
            let pointerTime = (state.point.x + scrollView.contentOffset.x) / scale
            var start = 0.0
            var destination = state.destination
            for (index, clip) in clips.enumerated() {
                let midpoint = start + clip.outputDuration / 2
                if index < state.destination, pointerTime < midpoint { destination = min(destination, index) }
                if index > state.destination, pointerTime > midpoint { destination = max(destination, index) }
                start += clip.outputDuration
            }
            if destination != state.destination {
                state.destination = destination
                reorderFeedback.selectionChanged()
                reorderFeedback.prepare()
            }
            reorder = state
            viewport.setNeedsDisplay()
        }

        private func scrollWhileReordering(_ link: CADisplayLink) {
            guard let state = reorder, !fitted else { return }
            let edge: CGFloat = 48
            let left = max(0, min(1, (edge - state.point.x) / edge))
            let right = max(0, min(1, (state.point.x - (bounds.width - edge)) / edge))
            let velocity = (right - left) * 280
            guard velocity != 0 else { return }
            let delta = velocity * min(1 / 30, link.targetTimestamp - link.timestamp)
            let offset = max(-scrollView.contentInset.left,
                             min(scrollView.contentSize.width - bounds.width + scrollView.contentInset.right,
                                 scrollView.contentOffset.x + delta))
            updatingOffset = true
            scrollView.contentOffset = CGPoint(x: offset, y: 0)
            updatingOffset = false
            updateReorderDestination()
        }

        private func finishReorder(commit: Bool) {
            reorderTicker?.invalidate()
            reorderTicker = nil
            guard let state = reorder else { return }
            reorder = nil
            if commit, let editor, state.original == editor.chunks, state.destination != state.originalIndex {
                let destination = state.destination > state.originalIndex ? state.destination + 1 : state.destination
                editor.moveMobileChunks(from: IndexSet(integer: state.originalIndex), to: destination)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
            editor?.endScrub()
            if let editor { setTime(editor.currentTime) }
            viewport.setNeedsDisplay()
            accessibilityElements = accessibilityItems()
        }

        @objc private func fitScrubbed(_ gesture: UIPanGestureRecognizer) {
            guard fitted, let editor else { return }
            switch gesture.state {
            case .began:
                editor.beginScrub()
                editor.scrub(to: time(at: gesture.location(in: self).x))
            case .changed:
                editor.scrub(to: time(at: gesture.location(in: self).x))
            case .ended, .cancelled, .failed:
                editor.endScrub()
                viewport.setNeedsDisplay()
            default: break
            }
        }

        private func handle(at point: CGPoint) -> (Chunk, EditorViewModel.TrimEdge)? {
            guard let editor, let chunk = editor.selectedMobileChunk else { return nil }
            let frame = clipFrame(chunk)
            guard frame.width >= 44, point.y >= frame.minY - 10, point.y <= frame.maxY + 10 else { return nil }
            if abs(point.x - frame.minX) <= 22 { return (chunk, .leading) }
            if abs(point.x - frame.maxX) <= 22 { return (chunk, .trailing) }
            return nil
        }

        @objc private func trimDragged(_ gesture: UIPanGestureRecognizer) {
            guard let editor else { return }
            switch gesture.state {
            case .began:
                // The initial touch matters: a finger may already have moved by
                // the time UIPanGestureRecognizer transitions to began.
                let now = gesture.location(in: self)
                let translation = gesture.translation(in: self)
                let origin = CGPoint(x: now.x - translation.x, y: now.y - translation.y)
                guard let (chunk, edge) = handle(at: origin) else { return }
                trim = TrimGesture(original: chunk, edge: edge,
                                   timelineStart: editor.timelineStart(for: chunk), preview: chunk)
                editor.beginTrimPreview(chunk.id)
                editor.beginScrub()
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                updateTrim(gesture)
            case .changed: updateTrim(gesture)
            case .ended:
                guard let state = trim else { return }
                trim = nil
                _ = editor.commitTrimPreview(state.preview)
                let target = state.timelineStart + (state.edge == .leading ? 0 : max(0, state.preview.outputDuration - 1 / 60))
                editor.scrub(to: target)
                editor.endScrub()
                setTime(editor.currentTime)
                viewport.setNeedsDisplay()
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case .cancelled, .failed:
                trim = nil
                editor.endScrub()
                setTime(editor.currentTime)
                viewport.setNeedsDisplay()
            default: break
            }
        }

        private func updateTrim(_ gesture: UIPanGestureRecognizer) {
            guard let editor, var state = trim else { return }
            let delta = gesture.translation(in: self).x / scale * state.original.speed
            state.preview = editor.trimPreview(from: state.original, edge: state.edge, sourceDelta: delta)
            trim = state
            let sourceTime = state.edge == .leading ? state.preview.start : state.preview.end
            editor.scrub(to: state.timelineStart + (sourceTime - state.original.start) / state.original.speed)
            viewport.setNeedsDisplay()
        }

        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let editor else { return }
            switch gesture.state {
            case .began:
                pinching = true
                pinchScale = scale
                pinchTime = editor.currentTime
                if fitted {
                    fitted = false
                    onScale?(scale)
                    onFitChange?(false)
                    configureInsets()
                    updateContentSize()
                    setTime(pinchTime)
                }
                editor.beginScrub()
            case .changed:
                scale = max(0.001, min(max(240, pinchScale), pinchScale * gesture.scale))
                updateContentSize()
                setTime(pinchTime)
                onScale?(scale)
                viewport.setNeedsDisplay()
            case .ended, .cancelled:
                pinching = false
                editor.endScrub()
            default: break
            }
        }

        private var trackTop: CGFloat { compact ? 24 : 30 }
        private var trackHeight: CGFloat { compact ? 40 : 70 }
        private var audioTop: CGFloat { trackTop + trackHeight + 8 }
        private var addedAudioTop: CGFloat { audioTop + (compact ? 40 : 52) }
        private var playheadBottom: CGFloat {
            guard showsAudio else { return trackTop + trackHeight + 9 }
            return (editor?.hasImportedAudioTrack == true ? addedAudioTop : audioTop) + (compact ? 35 : 47)
        }

        private func audioFrame(_ segment: MobileAudioSegment, y: CGFloat) -> CGRect {
            CGRect(x: segment.timelineStart * scale - scrollView.contentOffset.x,
                   y: y, width: segment.duration * scale, height: compact ? 32 : 44)
        }

        private func drawAudio(_ segments: [MobileAudioSegment], y: CGFloat, in context: CGContext) {
            guard let editor else { return }
            let spans = segments.map { AudioGainEnvelope.Span(start: $0.timelineStart, duration: $0.duration,
                                                              volume: $0.volume, fades: $0.fades) }
            for (segmentIndex, segment) in segments.enumerated() {
                let ramps = AudioGainEnvelope.ramps(at: segmentIndex, in: spans)
                let frame = audioFrame(segment, y: y)
                guard frame.intersects(bounds), frame.width > 0.5 else { continue }
                let rect = frame.insetBy(dx: min(1, frame.width / 4), dy: 0)
                let selected = editor.mobileAudioTarget == segment.target
                let muted = segment.volume == 0
                let color = UIColor(red: 0.24, green: 0.83, blue: 0.72, alpha: 1)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: min(7, rect.width / 4))
                context.saveGState()
                path.addClip()
                context.setFillColor(color.withAlphaComponent(selected ? 0.25 : 0.11).cgColor)
                context.fill(rect)
                if segment.hasAudio, let peaks = editor.mobileWaveforms[segment.sourceID], !peaks.isEmpty {
                    context.setFillColor(color.withAlphaComponent(muted ? 0.2 : 0.8).cgColor)
                    let firstX = max(0, rect.minX)
                    let lastX = min(bounds.width, rect.maxX)
                    for x in stride(from: firstX, through: lastX, by: 3) {
                        let fraction = max(0, min(1, (x - frame.minX) / frame.width))
                        let sourceTime = segment.start + fraction * (segment.end - segment.start)
                        let index = max(0, min(peaks.count - 1, Int(sourceTime / segment.sourceDuration * Double(peaks.count))))
                        let time = segment.timelineStart + fraction * segment.duration
                        let ramp = ramps.first { time >= $0.start && time <= $0.start + $0.duration }
                        let gain = ramp.map { $0.from + ($0.to - $0.from) * Float(max(0, min(1, (time - $0.start) / $0.duration))) } ?? segment.volume
                        let height = max(1, CGFloat(sqrt(peaks[index]) * gain) * (compact ? 14 : 25))
                        context.fill(CGRect(x: x, y: rect.minY + (compact ? 9 : 15) - height / 2, width: 1.5, height: height))
                    }
                }
                if rect.width > 48 {
                    let label: String
                    if !segment.hasAudio { label = "No audio" }
                    else if muted { label = "Muted" }
                    else { label = "\(Int((segment.volume * 100).rounded()))%" }
                    (label as NSString).draw(at: CGPoint(x: max(rect.minX + 7, 6), y: rect.maxY - 15), withAttributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                        .foregroundColor: color.withAlphaComponent(segment.hasAudio ? 1 : 0.4)
                    ])
                }
                context.restoreGState()
                context.setStrokeColor(color.withAlphaComponent(selected ? 1 : 0.25).cgColor)
                context.setLineWidth(selected ? 2 : 1)
                context.addPath(path.cgPath); context.strokePath()
            }
        }

        private func clipFrame(_ chunk: Chunk) -> CGRect {
            guard let editor else { return .zero }
            let clips = reorder?.preview ?? editor.chunks
            let start = clips.prefix { $0.id != chunk.id }.reduce(0) { $0 + $1.outputDuration }
            return CGRect(x: start * scale - scrollView.contentOffset.x,
                          y: trackTop, width: chunk.outputDuration * scale, height: trackHeight)
        }

        fileprivate func draw(in context: CGContext) {
            guard let editor else { return }
            drawRuler(in: context, duration: editor.totalDuration)
            let blankWidth = min(bounds.width, -scrollView.contentOffset.x)
            if blankWidth > 120 {
                let hint = editor.selectedMobileChunk == nil ? "Drag to scrub" : "Drag edges to trim"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.45)
                ]
                let size = (hint as NSString).size(withAttributes: attributes)
                (hint as NSString).draw(at: CGPoint(x: (blankWidth - size.width) / 2,
                                                   y: trackTop + trackHeight / 2 - size.height / 2), withAttributes: attributes)
            }
            var timelineStart = 0.0
            var selected: (Chunk, CGRect)?
            for chunk in reorder?.preview ?? editor.chunks {
                var frame = CGRect(x: timelineStart * scale - scrollView.contentOffset.x,
                                   y: trackTop, width: chunk.outputDuration * scale, height: trackHeight)
                timelineStart += chunk.outputDuration
                if reorder?.chunk.id == chunk.id {
                    let slot = UIBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: 9)
                    context.setFillColor(UIColor(Theme.accent).withAlphaComponent(0.12).cgColor)
                    context.addPath(slot.cgPath); context.fillPath()
                    context.saveGState()
                    context.setStrokeColor(UIColor(Theme.accent).withAlphaComponent(0.7).cgColor)
                    context.setLineWidth(1.5)
                    context.setLineDash(phase: 0, lengths: [4, 4])
                    context.addPath(slot.cgPath); context.strokePath()
                    context.restoreGState()
                    continue
                }
                var displayed = chunk
                if let trim, trim.original.id == chunk.id {
                    displayed = trim.preview
                    if trim.edge == .leading {
                        frame.origin.x += (displayed.start - chunk.start) / chunk.speed * scale
                    }
                    frame.size.width = displayed.outputDuration * scale
                }
                if editor.selection.contains(chunk.id) { selected = (displayed, frame) }
                else { drawClip(displayed, frame: frame, selected: false, in: context) }
            }
            if let (chunk, frame) = selected { drawClip(chunk, frame: frame, selected: true, in: context) }
            if showsAudio {
                drawAudio(editor.mobileVideoAudioSegments, y: audioTop, in: context)
                drawAudio(editor.mobileAddedAudioSegments, y: addedAudioTop, in: context)
            }

            // One playhead for preview, scrubbing, playback, and split operations.
            context.setShadow(offset: .zero, blur: 4, color: UIColor.black.cgColor)
            context.setFillColor(UIColor.white.cgColor)
            let x = fitted || trim != nil ? editor.currentTime * scale - scrollView.contentOffset.x : bounds.midX
            context.fill(CGRect(x: x - 1, y: trackTop - 7, width: 2, height: playheadBottom - trackTop + 7))
            let cap = UIBezierPath(roundedRect: CGRect(x: x - 5, y: trackTop - 13, width: 10, height: 8), cornerRadius: 3)
            context.addPath(cap.cgPath); context.fillPath()
            context.setShadow(offset: .zero, blur: 0)

            if let reorder {
                let frame = CGRect(x: reorder.point.x + reorder.grabOffset - reorder.liftedWidth / 2,
                                   y: trackTop - 8, width: reorder.liftedWidth, height: trackHeight)
                let card = UIBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 0), cornerRadius: 9)
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: 5), blur: 12, color: UIColor.black.cgColor)
                context.setFillColor(UIColor(Theme.panelHi).cgColor)
                context.addPath(card.cgPath); context.fillPath()
                context.setShadow(offset: .zero, blur: 0)
                drawClip(reorder.chunk, frame: frame, selected: false, in: context)
                context.setStrokeColor(UIColor(Theme.accent).cgColor)
                context.setLineWidth(2.5)
                context.addPath(card.cgPath); context.strokePath()
                context.restoreGState()
            }
        }

        private func drawRuler(in context: CGContext, duration: Double) {
            let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
            let step = steps.first { $0 * scale >= 48 } ?? 3600
            let first = max(0, floor(scrollView.contentOffset.x / scale / step))
            let last = min(ceil(duration / step), ceil((scrollView.contentOffset.x + bounds.width) / scale / step))
            guard first <= last else { return }
            for tick in Int(first)...Int(last) {
                let time = Double(tick) * step
                guard time <= duration + 0.001 else { continue }
                let x = time * scale - scrollView.contentOffset.x
                let label = step < 1 ? String(format: "%.1fs", time) : timecode(time)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.5)
                ]
                let text = label as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: x - size.width / 2, y: 1), withAttributes: attributes)
                context.setFillColor(UIColor.white.withAlphaComponent(0.18).cgColor)
                context.fill(CGRect(x: x - 0.5, y: trackTop - 10, width: 1, height: 4))
                let minorX = x + step * scale / 2
                if time + step / 2 <= duration {
                    context.fill(CGRect(x: minorX - 0.5, y: trackTop - 7, width: 1, height: 2))
                }
            }
        }

        private func drawClip(_ chunk: Chunk, frame: CGRect, selected: Bool, in context: CGContext) {
            guard frame.intersects(bounds), frame.width > 0.5, let editor else { return }
            let rect = frame.insetBy(dx: min(1, frame.width / 4), dy: 0)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: min(9, frame.width / 4))
            context.saveGState()
            path.addClip()
            context.setFillColor(UIColor(Theme.panelHi).cgColor)
            context.fill(rect)
            let tileWidth: CGFloat = 48
            let first = max(0, Int(floor((max(0, rect.minX) - rect.minX) / tileWidth)))
            let last = max(first, Int(ceil((min(bounds.width, rect.maxX) - rect.minX) / tileWidth)))
            for index in first...last {
                let tile = CGRect(x: rect.minX + CGFloat(index) * tileWidth, y: rect.minY,
                                  width: tileWidth, height: rect.height)
                let fraction = min(1, max(0, (tile.midX - rect.minX) / max(1, rect.width)))
                let sourceTime = chunk.start + fraction * chunk.sourceDuration
                if let image = editor.thumbnail(sourceID: chunk.sourceID, near: sourceTime) {
                    let fit = max(tile.width / max(1, image.size.width), tile.height / max(1, image.size.height))
                    let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
                    context.saveGState(); context.clip(to: tile)
                    image.draw(in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                                          width: size.width, height: size.height))
                    context.restoreGState()
                }
            }
            context.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 22, width: rect.width, height: 22))
            if rect.width > 56 {
                let label = "\(timecode(chunk.outputDuration))  ·  \(speedLabel(chunk.speed))"
                let x = max(rect.minX + (selected ? 16 : 8), 8)
                (label as NSString).draw(at: CGPoint(x: x, y: rect.maxY - 17), withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: UIColor.white
                ])
            }
            context.restoreGState()
            context.setStrokeColor((selected ? UIColor(Theme.accent) : UIColor.white.withAlphaComponent(0.15)).cgColor)
            context.setLineWidth(selected ? 2.5 : 1)
            context.addPath(path.cgPath); context.strokePath()
            if selected, frame.width >= 44 {
                context.setFillColor(UIColor(Theme.accent).cgColor)
                context.addPath(UIBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: 12, height: rect.height), cornerRadius: 4).cgPath)
                context.fillPath()
                context.addPath(UIBezierPath(roundedRect: CGRect(x: rect.maxX - 12, y: rect.minY, width: 12, height: rect.height), cornerRadius: 4).cgPath)
                context.fillPath()
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(x: rect.minX + 5, y: rect.midY - 8, width: 2, height: 16))
                context.fill(CGRect(x: rect.maxX - 7, y: rect.midY - 8, width: 2, height: 16))
            }
        }

        fileprivate func accessibilityItems() -> [Any] {
            guard let editor else { return [] }
            let playhead = TimelineAccessibilityElement(accessibilityContainer: self)
            playhead.accessibilityLabel = "Timeline playhead"
            playhead.accessibilityIdentifier = "timelinePlayhead"
            playhead.accessibilityValue = timecode(editor.currentTime, showCentis: true)
            playhead.accessibilityTraits = .adjustable
            let playheadX = fitted ? editor.currentTime * scale - scrollView.contentOffset.x : bounds.midX
            playhead.accessibilityFrameInContainerSpace = CGRect(x: playheadX - 20, y: 0, width: 40, height: bounds.height).intersection(bounds)
            playhead.adjust = { [weak self] direction in
                guard let self, let editor = self.editor else { return }
                editor.beginScrub(); editor.scrub(to: editor.currentTime + Double(direction) / 30); editor.endScrub()
                self.setTime(editor.currentTime); self.viewport.setNeedsDisplay()
            }
            var result: [Any] = [scrollView, playhead]
            if showsAudio {
                for (segments, y, prefix, name) in [(editor.mobileVideoAudioSegments, audioTop, "audio-section", "Clip audio"),
                                                  (editor.mobileAddedAudioSegments, addedAudioTop, "added-audio", "Added audio")] {
                    for (index, segment) in segments.enumerated() {
                        let frame = audioFrame(segment, y: y)
                        guard frame.intersects(bounds), segment.hasAudio else { continue }
                        let audio = TimelineAccessibilityElement(accessibilityContainer: self)
                        audio.accessibilityIdentifier = "\(prefix)-\(index)"
                        audio.accessibilityLabel = "\(name) section \(index + 1)"
                        audio.accessibilityValue = "\(Int((segment.volume * 100).rounded())) percent"
                        audio.accessibilityTraits = editor.mobileAudioTarget == segment.target ? [.button, .selected] : .button
                        audio.accessibilityHint = "Select to adjust volume. Split at the playhead to isolate a spot."
                        audio.accessibilityFrameInContainerSpace = frame.intersection(bounds)
                        audio.activate = { [weak editor] in editor?.selectMobileAudio(segment.target) }
                        result.append(audio)
                    }
                }
            }
            for (index, chunk) in editor.chunks.enumerated() {
                let frame = clipFrame(chunk)
                guard frame.intersects(bounds) else { continue }
                let clip = TimelineAccessibilityElement(accessibilityContainer: self)
                clip.accessibilityLabel = "Clip \(index + 1), \(timecode(chunk.outputDuration)), \(speedLabel(chunk.speed))"
                clip.accessibilityIdentifier = "clip-\(index)"
                clip.accessibilityValue = "Source \(timecode(chunk.start, showCentis: true)) to \(timecode(chunk.end, showCentis: true))"
                clip.accessibilityHint = "Hold and drag to reorder. Tap to select and trim."
                clip.accessibilityTraits = editor.selection.contains(chunk.id) ? [.button, .selected] : .button
                clip.accessibilityFrameInContainerSpace = frame.intersection(bounds)
                clip.activate = { [weak self, weak editor] in
                    editor?.beginTrimPreview(chunk.id); self?.viewport.setNeedsDisplay()
                }
                clip.accessibilityCustomActions = [
                    ("Move earlier", index - 1), ("Move later", index + 1)
                ].compactMap { name, target in
                    guard editor.chunks.indices.contains(target) else { return nil }
                    return UIAccessibilityCustomAction(name: name) { [weak editor] _ in
                        guard let editor, let current = editor.chunks.firstIndex(where: { $0.id == chunk.id }) else { return false }
                        editor.moveMobileChunks(from: IndexSet(integer: current), to: target > current ? target + 1 : target)
                        return true
                    }
                }
                result.append(clip)
                if editor.selection.contains(chunk.id), frame.width >= 44 {
                    for edge in [EditorViewModel.TrimEdge.leading, .trailing] {
                        let x = edge == .leading ? frame.minX : frame.maxX
                        guard x >= 0, x <= bounds.width else { continue }
                        let handle = TimelineAccessibilityElement(accessibilityContainer: self)
                        handle.accessibilityLabel = edge == .leading ? "Trim clip start" : "Trim clip end"
                        handle.accessibilityIdentifier = edge == .leading ? "trimHandleStart" : "trimHandleEnd"
                        handle.accessibilityTraits = .adjustable
                        handle.accessibilityFrameInContainerSpace = CGRect(x: x - 16, y: frame.minY, width: 32, height: frame.height).intersection(bounds)
                        handle.adjust = { [weak self, weak editor] direction in
                            guard let editor else { return }
                            let preview = editor.trimPreview(from: chunk, edge: edge, sourceDelta: Double(direction) / 30 * chunk.speed)
                            _ = editor.commitTrimPreview(preview)
                            self?.viewport.setNeedsDisplay()
                        }
                        result.append(handle)
                    }
                }
            }
            return result
        }
    }
}

private final class TimelineViewport: UIView {
    weak var owner: MobileTimelineView.TimelineView?
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        owner?.draw(in: context)
    }
}

private final class TimelineAccessibilityElement: UIAccessibilityElement {
    override init(accessibilityContainer container: Any) {
        super.init(accessibilityContainer: container)
        isAccessibilityElement = true
    }
    var activate: (() -> Void)?
    var adjust: ((Int) -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
    override func accessibilityIncrement() { adjust?(1) }
    override func accessibilityDecrement() { adjust?(-1) }
}
