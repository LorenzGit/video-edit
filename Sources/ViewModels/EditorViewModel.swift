import SwiftUI
import AVFoundation
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Owns all editing state: the loaded source videos, the list of chunks, the
/// preview player, undo/redo history, thumbnails and MP4 export.
@MainActor
final class EditorViewModel: ObservableObject {

    /// One imported video file and everything we need to render from it.
    struct Source: Identifiable {
        let id: UUID
        let url: URL
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let duration: Double
        let preferredTransform: CGAffineTransform
        let naturalSize: CGSize     // oriented (preferredTransform applied)
        let frameRate: Float
    }

    // MARK: Sources

    @Published private(set) var sourceURL: URL?       // first loaded file; nil = empty project
    @Published private(set) var hasAudio: Bool = false
    private var sources: [UUID: Source] = [:]

    // MARK: Timeline model

    @Published var chunks: [Chunk] = []
    @Published var selection: Set<UUID> = []

    var hasContent: Bool { sourceURL != nil && !chunks.isEmpty }

    /// Drops the audio track from both the preview and the export.
    @Published var muteAudio: Bool = false {
        didSet { if oldValue != muteAudio { rebuild() } }
    }

    /// Slowest allowed speed. There is no upper limit — type any value you like.
    static let minSpeed: Double = 0.1

    /// Name shown in the toolbar (primary file, plus a count when there are more).
    var displayName: String {
        var seen = Set<UUID>()
        var names: [String] = []
        for chunk in chunks where !seen.contains(chunk.sourceID) {
            seen.insert(chunk.sourceID)
            if let name = sources[chunk.sourceID]?.url.lastPathComponent { names.append(name) }
        }
        guard let first = names.first else { return "" }
        return names.count > 1 ? "\(first)  +\(names.count - 1)" : first
    }

    // MARK: Timeline zoom

    @Published var pps: Double?               // pixels-per-second; nil = fit to width
    var timelineWidth: CGFloat = 1

    var isFitZoom: Bool { pps == nil }
    private var fitScale: Double { Double(timelineWidth) / max(totalDuration, 0.0001) }

    func zoomToFit() { pps = nil }
    func zoomIn() { let current = pps ?? fitScale; pps = min(current * 1.6, 1200) }
    func zoomOut() {
        let fit = fitScale
        let current = pps ?? fit
        let next = current / 1.6
        pps = next <= fit * 1.02 ? nil : next
    }

    // MARK: Undo / redo

    private struct Snapshot { var chunks: [Chunk]; var selection: Set<UUID> }
    private var past: [Snapshot] = []
    private var future: [Snapshot] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    // MARK: Playback

    let player = AVPlayer()
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var totalDuration: Double = 0
    var isScrubbing = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    // MARK: Thumbnails

    struct ThumbFrame: Identifiable { let id = UUID(); let time: Double; let image: NSImage }
    @Published private(set) var thumbnails: [UUID: [ThumbFrame]] = [:]
    private var thumbTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Export

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published private(set) var exportProgressTitle = "Exporting MP4"
    @Published private(set) var exportProgressIcon = "square.and.arrow.up"
    @Published var statusMessage: String?
    private var clipboardVideoURL: URL?

    private let timescale: CMTimeScale = 600

    // MARK: Screen recording

    @Published private(set) var isPreparingRecording = false
    @Published private(set) var isSelectingCaptureRegion = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishingRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published var recordsSystemAudio = true

    private var captureSelectionCoordinator: CaptureSelectionCoordinator?
    private var screenRecorder: ScreenRecorder?
    private var recordingStatusItem: RecordingStatusItemController?
    private var recordingTimer: Task<Void, Never>?
    private var stopRecordingHotKey: GlobalHotKey?
    private var concealedWindows: [NSWindow] = []

    var recordingActionDisabled: Bool {
        isPreparingRecording || isSelectingCaptureRegion || isFinishingRecording
    }

    // MARK: Lifecycle

    init() {
        player.actionAtItemEnd = .pause
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        recordingTimer?.cancel()
    }

    // MARK: Loading & importing

    func beginScreenRecording() {
        guard !isRecording, !recordingActionDisabled, !isExporting else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }

        statusMessage = nil
        isPreparingRecording = true
        Task {
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }

            do {
                // Fetch shareable content before placing selection overlays so
                // we only offer displays ScreenCaptureKit can actually capture.
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                let displayIDs = Set(content.displays.map(\.displayID))
                concealReelWindowsForCapture()
                isPreparingRecording = false
                isSelectingCaptureRegion = true

                let coordinator = CaptureSelectionCoordinator(
                    includeSystemAudio: recordsSystemAudio
                )
                captureSelectionCoordinator = coordinator
                coordinator.present(availableDisplayIDs: displayIDs) { [weak self] selection in
                    guard let self else { return }
                    self.captureSelectionCoordinator = nil
                    self.isSelectingCaptureRegion = false
                    guard let selection else {
                        self.revealReelWindowsAfterCapture()
                        return
                    }
                    self.recordsSystemAudio = selection.includeSystemAudio
                    self.startScreenRecording(selection)
                }
            } catch {
                isPreparingRecording = false
                revealReelWindowsAfterCapture()
                handleScreenCaptureError(error)
            }
        }
    }

    func stopScreenRecording() {
        guard isRecording, !isFinishingRecording, let recorder = screenRecorder else { return }
        let shouldAppendRecording = hasContent
        isFinishingRecording = true
        recordingTimer?.cancel()
        recordingTimer = nil
        recordingStatusItem?.setFinishing()

        Task {
            do {
                let url = try await recorder.stop()
                finishRecordingUI()
                if shouldAppendRecording {
                    if await appendImport(url: url) {
                        statusMessage = "Recording saved to Movies/Reel and appended to the timeline."
                    }
                } else if await loadFresh(url: url) {
                    statusMessage = "Recording saved to Movies/Reel and opened for editing."
                }
            } catch {
                finishRecordingUI()
                statusMessage = "Couldn't finish recording: \(error.localizedDescription)"
            }
        }
    }

    private func startScreenRecording(_ selection: ScreenCaptureSelection) {
        isPreparingRecording = true
        Task {
            // Let the border and control panels leave the window server before
            // capture begins. Reel is also excluded from the stream itself.
            try? await Task.sleep(nanoseconds: 120_000_000)

            let recorder = ScreenRecorder()
            recorder.unexpectedStopHandler = { [weak self, weak recorder] error in
                Task { @MainActor in
                    recorder?.cancel()
                    self?.finishRecordingUI()
                    self?.statusMessage = "Screen recording stopped: \(error.localizedDescription)"
                }
            }
            screenRecorder = recorder

            do {
                _ = try await recorder.start(
                    selection: selection,
                    includeSystemAudio: selection.includeSystemAudio
                )
                isPreparingRecording = false
                isRecording = true
                recordingElapsed = 0
                stopRecordingHotKey = GlobalHotKey(commandEscapeAction: { [weak self] in
                    self?.stopScreenRecording()
                })

                recordingStatusItem = RecordingStatusItemController { [weak self] in
                    self?.stopScreenRecording()
                }

                let startedAt = Date()
                recordingTimer = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.recordingElapsed = Date().timeIntervalSince(startedAt)
                        self.recordingStatusItem?.update(elapsed: self.recordingElapsed)
                    }
                }
            } catch {
                recorder.cancel()
                finishRecordingUI()
                handleScreenCaptureError(error)
            }
        }
    }

    private func finishRecordingUI() {
        recordingTimer?.cancel()
        recordingTimer = nil
        stopRecordingHotKey = nil
        recordingStatusItem?.close()
        recordingStatusItem = nil
        screenRecorder = nil
        isPreparingRecording = false
        isRecording = false
        isFinishingRecording = false
        recordingElapsed = 0
        revealReelWindowsAfterCapture()
    }

    private func concealReelWindowsForCapture() {
        guard concealedWindows.isEmpty else { return }
        concealedWindows = NSApp.windows.filter { window in
            window.isVisible && !(window is NSPanel)
        }
        concealedWindows.forEach { $0.orderOut(nil) }
    }

    private func revealReelWindowsAfterCapture() {
        guard !concealedWindows.isEmpty else { return }
        let windows = concealedWindows
        concealedWindows.removeAll()
        windows.dropFirst().forEach { $0.orderFront(nil) }
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleScreenCaptureError(_ error: Error) {
        if !CGPreflightScreenCaptureAccess() {
            statusMessage = nil
            openScreenRecordingSettings()
            return
        }
        statusMessage = "Couldn't start screen recording: \(error.localizedDescription)"
    }

    private func openScreenRecordingSettings() {
        let workspace = NSWorkspace.shared
        let deepLink = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        if let deepLink, workspace.open(deepLink) {
            return
        }

        // Fall back to opening System Settings itself if Apple changes the
        // privacy-pane deep link on a future macOS release.
        let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        workspace.open(settingsApp)
    }

    func openPanel() {
        if let url = pickVideo(title: "Open Video") { openVideo(url: url) }
    }

    /// Opens a panel to append another video at the end of the timeline.
    func importPanel() {
        guard hasContent else { openPanel(); return }
        if let url = pickVideo(title: "Import Video") { importVideo(url: url) }
    }

    private func pickVideo(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = title
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openVideo(url: URL) { Task { await loadFresh(url: url) } }
    func importVideo(url: URL) { Task { await appendImport(url: url) } }

    private func makeSource(url: URL) async throws -> Source? {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else { return nil }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let transform = try await video.load(.preferredTransform)
        let size = try await video.load(.naturalSize)
        let fps = (try? await video.load(.nominalFrameRate)) ?? 30
        let oriented = size.applying(transform)
        return Source(
            id: UUID(), url: url, asset: asset, videoTrack: video, audioTrack: audioTracks.first,
            duration: duration.seconds, preferredTransform: transform,
            naturalSize: CGSize(width: abs(oriented.width), height: abs(oriented.height)),
            frameRate: fps == 0 ? 30 : fps
        )
    }

    @discardableResult
    private func loadFresh(url: URL) async -> Bool {
        statusMessage = nil
        muteAudio = false
        do {
            guard let source = try await makeSource(url: url) else {
                statusMessage = "That file has no video track."
                return false
            }
            sources = [source.id: source]
            hasAudio = source.audioTrack != nil
            sourceURL = url
            chunks = [Chunk(sourceID: source.id, start: 0, end: source.duration)]
            selection = []
            past = []
            future = []
            currentTime = 0
            pps = nil
            thumbnails = [:]
            rebuild(seekTo: 0)
            generateThumbnails(for: source)
            return true
        } catch {
            statusMessage = "Couldn't load video: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func appendImport(url: URL) async -> Bool {
        do {
            guard let source = try await makeSource(url: url) else {
                statusMessage = "That file has no video track."
                return false
            }
            sources[source.id] = source
            hasAudio = hasAudio || source.audioTrack != nil
            let newChunk = Chunk(sourceID: source.id, start: 0, end: source.duration)
            commit {
                chunks.append(newChunk)
                selection = [newChunk.id]
            }
            generateThumbnails(for: source)
            statusMessage = "Appended \(url.lastPathComponent)"
            return true
        } catch {
            statusMessage = "Couldn't import video: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Composition

    /// Builds the edited timeline as a composition plus a video composition that
    /// places each source (whatever its size/orientation) into a common frame.
    private func buildComposition() -> (composition: AVMutableComposition, video: AVMutableVideoComposition)? {
        guard let first = chunks.first, let firstSource = sources[first.sourceID] else { return nil }
        let comp = AVMutableComposition()
        guard let compVideo = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        let needsAudio = !muteAudio && chunks.contains { sources[$0.sourceID]?.audioTrack != nil }
        let compAudio = needsAudio
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        let renderSize = evenSize(firstSource.naturalSize)
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for chunk in chunks {
            guard let source = sources[chunk.sourceID], chunk.sourceDuration > 0 else { continue }
            let start = CMTime(seconds: chunk.start, preferredTimescale: timescale)
            let dur = CMTime(seconds: chunk.sourceDuration, preferredTimescale: timescale)
            let range = CMTimeRange(start: start, duration: dur)

            do { try compVideo.insertTimeRange(range, of: source.videoTrack, at: cursor) }
            catch { continue }
            if let compAudio, let audio = source.audioTrack {
                try? compAudio.insertTimeRange(range, of: audio, at: cursor)
            }

            let segmentStart = cursor
            var segmentDuration = dur
            if chunk.speed != 1.0 {
                let scaled = CMTime(seconds: dur.seconds / chunk.speed, preferredTimescale: timescale)
                compVideo.scaleTimeRange(CMTimeRange(start: cursor, duration: dur), toDuration: scaled)
                compAudio?.scaleTimeRange(CMTimeRange(start: cursor, duration: dur), toDuration: scaled)
                segmentDuration = scaled
            }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: segmentStart, duration: segmentDuration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            layer.setTransform(fitTransform(for: source, into: renderSize), at: segmentStart)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = segmentStart + segmentDuration
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        let fps = max(24, min(60, Double(firstSource.frameRate)))
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        videoComp.instructions = instructions
        return (comp, videoComp)
    }

    /// Transform that orients a source frame and aspect-fits it, centred, into `renderSize`.
    private func fitTransform(for source: Source, into renderSize: CGSize) -> CGAffineTransform {
        let oriented = source.naturalSize
        guard oriented.width > 0, oriented.height > 0 else { return source.preferredTransform }
        let scale = min(renderSize.width / oriented.width, renderSize.height / oriented.height)
        let tx = (renderSize.width - oriented.width * scale) / 2
        let ty = (renderSize.height - oriented.height * scale) / 2
        return source.preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    private func evenSize(_ size: CGSize) -> CGSize {
        let w = max(2, (Int(size.width.rounded()) / 2) * 2)
        let h = max(2, (Int(size.height.rounded()) / 2) * 2)
        return CGSize(width: w, height: h)
    }

    private func rebuild(seekTo time: Double? = nil) {
        totalDuration = chunks.reduce(0) { $0 + $1.outputDuration }
        guard let built = buildComposition(), totalDuration > 0 else {
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.video
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        seek(to: time ?? min(currentTime, totalDuration))
    }

    // MARK: Transport

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= totalDuration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double, precise: Bool = true) {
        let clamped = max(0, min(time, totalDuration))
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: timescale)
        if precise {
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tol = CMTime(seconds: 0.08, preferredTimescale: timescale)
            player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
        }
    }

    func beginScrub() {
        if isPlaying { player.pause(); isPlaying = false }
        isScrubbing = true
    }

    func scrub(to time: Double) {
        if !isScrubbing { beginScrub() }
        seek(to: time, precise: false)
    }

    func endScrub() {
        isScrubbing = false
        seek(to: currentTime, precise: true)
    }

    // MARK: Editing operations

    private func snapshot() -> Snapshot { Snapshot(chunks: chunks, selection: selection) }

    private func commit(_ action: () -> Void) {
        past.append(snapshot())
        future.removeAll()
        action()
        rebuild()
    }

    private func chunkAtPlayhead() -> (index: Int, local: Double, start: Double)? {
        guard !chunks.isEmpty else { return nil }
        var accumulated = 0.0
        for (index, chunk) in chunks.enumerated() {
            let out = chunk.outputDuration
            if currentTime >= accumulated - 1e-6 && currentTime < accumulated + out - 1e-6 {
                return (index, currentTime - accumulated, accumulated)
            }
            accumulated += out
        }
        return nil
    }

    func splitAtPlayhead() {
        guard let (index, local, _) = chunkAtPlayhead() else { return }
        let chunk = chunks[index]
        if local <= 0.02 || local >= chunk.outputDuration - 0.02 { return }
        let sourceSplit = chunk.start + local * chunk.speed
        commit {
            let first = Chunk(id: chunk.id, sourceID: chunk.sourceID, start: chunk.start, end: sourceSplit, speed: chunk.speed)
            let second = Chunk(sourceID: chunk.sourceID, start: sourceSplit, end: chunk.end, speed: chunk.speed)
            chunks.replaceSubrange(index...index, with: [first, second])
            selection = [second.id]
        }
    }

    func deleteBeforePlayhead() {
        guard let (index, local, start) = chunkAtPlayhead() else { return }
        let chunk = chunks[index]
        guard local > 0.02 else { return }
        let sourceSplit = chunk.start + local * chunk.speed
        commit {
            chunks[index].start = sourceSplit
            selection = [chunks[index].id]
        }
        seek(to: start)
    }

    func deleteAfterPlayhead() {
        guard let (index, local, start) = chunkAtPlayhead() else { return }
        let chunk = chunks[index]
        guard local < chunk.outputDuration - 0.02 else { return }
        let sourceSplit = chunk.start + local * chunk.speed
        commit {
            chunks[index].end = sourceSplit
            selection = [chunks[index].id]
        }
        seek(to: start + local)
    }

    func deleteSelected() {
        guard chunks.contains(where: { selection.contains($0.id) }) else { return }
        commit {
            chunks.removeAll { selection.contains($0.id) }
            selection = []
        }
    }

    func delete(_ id: UUID) {
        guard chunks.contains(where: { $0.id == id }) else { return }
        commit {
            chunks.removeAll { $0.id == id }
            selection.remove(id)
        }
    }

    // MARK: Non-destructive trimming

    enum TrimEdge: Equatable {
        case leading
        case trailing
    }

    /// Pauses playback and selects the clip before a trim preview starts.
    /// The actual chunk is left untouched until the gesture ends.
    func beginTrimPreview(_ id: UUID) {
        guard chunks.contains(where: { $0.id == id }) else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        selection = [id]
    }

    /// Produces a clamped, non-mutating trim preview. Because every pointer event
    /// is calculated from the same original chunk, reversing direction during a
    /// drag is exact and cannot accumulate rounding error.
    func trimPreview(
        from original: Chunk,
        edge: TrimEdge,
        sourceDelta: Double
    ) -> Chunk {
        guard
            chunks.contains(where: { $0.id == original.id }),
            let source = sources[original.sourceID]
        else { return original }

        let minimumDuration = min(
            source.duration,
            max(0.02, 1 / max(Double(source.frameRate), 1))
        )
        var updated = original

        switch edge {
        case .leading:
            updated.start = min(
                max(0, original.start + sourceDelta),
                original.end - minimumDuration
            )
        case .trailing:
            updated.end = max(
                original.start + minimumDuration,
                min(source.duration, original.end + sourceDelta)
            )
        }

        return updated
    }

    /// Applies the final preview once, creating one undo step and rebuilding the
    /// player only after the pointer is released.
    @discardableResult
    func commitTrimPreview(_ preview: Chunk) -> Bool {
        guard
            let index = chunks.firstIndex(where: { $0.id == preview.id }),
            chunks[index] != preview,
            chunks[index].sourceID == preview.sourceID
        else { return false }

        commit {
            chunks[index] = preview
            selection = [preview.id]
        }
        return true
    }

    func canRestoreTrim(_ id: UUID, edge: TrimEdge) -> Bool {
        recoverableTrimDuration(id, edge: edge) > 0.001
    }

    func recoverableTrimDuration(_ id: UUID, edge: TrimEdge) -> Double {
        guard
            let chunk = chunks.first(where: { $0.id == id }),
            let source = sources[chunk.sourceID]
        else { return 0 }
        switch edge {
        case .leading:
            return max(0, chunk.start)
        case .trailing:
            return max(0, source.duration - chunk.end)
        }
    }

    /// Restores one edge all the way to its original source boundary.
    func restoreTrim(_ id: UUID, edge: TrimEdge) {
        guard
            let index = chunks.firstIndex(where: { $0.id == id }),
            let source = sources[chunks[index].sourceID],
            canRestoreTrim(id, edge: edge)
        else { return }

        commit {
            switch edge {
            case .leading:
                chunks[index].start = 0
            case .trailing:
                chunks[index].end = source.duration
            }
            selection = [id]
        }
    }

    /// Applies a speed to the selected chunks, or to every chunk when `all`.
    func setSpeed(_ speed: Double, all: Bool = false) {
        guard speed.isFinite, speed > 0 else { return }
        let clamped = max(speed, Self.minSpeed)
        let targets: Set<UUID> = all ? Set(chunks.map(\.id)) : selection
        guard !targets.isEmpty else { return }
        let needsChange = chunks.contains { targets.contains($0.id) && $0.speed != clamped }
        guard needsChange else { return }
        commit {
            for index in chunks.indices where targets.contains(chunks[index].id) {
                chunks[index].speed = clamped
            }
        }
    }

    // MARK: Reordering

    private var singleSelectedIndex: Int? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return chunks.firstIndex { $0.id == id }
    }

    var canMoveBackward: Bool { if let i = singleSelectedIndex { return i > 0 }; return false }
    var canMoveForward: Bool { if let i = singleSelectedIndex { return i < chunks.count - 1 }; return false }

    /// Moves the single selected clip one slot earlier (-1) or later (+1).
    func moveSelected(by offset: Int) {
        guard let i = singleSelectedIndex else { return }
        let j = i + offset
        guard chunks.indices.contains(j) else { return }
        commit { chunks.swapAt(i, j) }
    }

    /// Reorders a clip relative to another clip. Used by timeline drag-and-drop;
    /// the whole move is recorded as one undoable action.
    @discardableResult
    func moveChunk(_ id: UUID, relativeTo targetID: UUID, after: Bool) -> Bool {
        guard
            id != targetID,
            let sourceIndex = chunks.firstIndex(where: { $0.id == id }),
            let targetIndex = chunks.firstIndex(where: { $0.id == targetID })
        else { return id == targetID }

        var insertionIndex = targetIndex + (after ? 1 : 0)
        if sourceIndex < insertionIndex { insertionIndex -= 1 }
        guard insertionIndex != sourceIndex else {
            selection = [id]
            return true
        }

        commit {
            let moved = chunks.remove(at: sourceIndex)
            chunks.insert(moved, at: min(max(0, insertionIndex), chunks.count))
            selection = [id]
        }
        return true
    }

    // MARK: Undo / redo

    func undo() {
        guard let snap = past.popLast() else { return }
        future.append(snapshot())
        chunks = snap.chunks
        selection = snap.selection
        rebuild()
    }

    func redo() {
        guard let snap = future.popLast() else { return }
        past.append(snapshot())
        chunks = snap.chunks
        selection = snap.selection
        rebuild()
    }

    // MARK: Selection

    func select(_ id: UUID, additive: Bool) {
        if additive {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func clearSelection() { selection = [] }

    /// A representative speed for the current selection (or whole timeline).
    var activeSpeed: Double? {
        let targets = selection.isEmpty ? Set(chunks.map(\.id)) : selection
        let speeds = Set(chunks.filter { targets.contains($0.id) }.map(\.speed))
        return speeds.count == 1 ? speeds.first : nil
    }

    // MARK: Thumbnails

    private func generateThumbnails(for source: Source) {
        thumbTasks[source.id]?.cancel()
        thumbnails[source.id] = []
        guard source.duration > 0 else { return }

        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: timescale)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: timescale)

        let count = min(120, max(10, Int(source.duration)))
        let step = source.duration / Double(count)
        let times = (0..<count).map {
            CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: timescale)
        }
        let sid = source.id

        thumbTasks[sid] = Task { [weak self] in
            for await frame in generator.images(for: times) {
                if Task.isCancelled { return }
                guard let cg = try? frame.image else { continue }
                let image = NSImage(cgImage: cg, size: .zero)
                let time = frame.requestedTime.seconds
                self?.thumbnails[sid, default: []].append(ThumbFrame(time: time, image: image))
                self?.thumbnails[sid]?.sort { $0.time < $1.time }
            }
        }
    }

    /// Nearest cached thumbnail in a source to a given source time.
    func thumbnail(sourceID: UUID, near time: Double) -> NSImage? {
        guard let frames = thumbnails[sourceID], !frames.isEmpty else { return nil }
        var best: NSImage?
        var bestDiff = Double.greatestFiniteMagnitude
        for frame in frames {
            let diff = abs(frame.time - time)
            if diff < bestDiff { bestDiff = diff; best = frame.image }
        }
        return best
    }

    /// Display aspect ratio of a source, for laying out filmstrip tiles.
    func aspect(sourceID: UUID) -> CGFloat {
        guard let source = sources[sourceID] else { return 16.0 / 9.0 }
        return max(0.4, source.naturalSize.width / max(source.naturalSize.height, 1))
    }

    // MARK: Export

    func export() {
        guard hasContent else { statusMessage = "Nothing to export."; return }
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = defaultExportName()
        panel.canCreateDirectories = true
        panel.title = "Export Video"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await runExport(to: url, destination: .file) }
    }

    func copyVideo() {
        guard hasContent else { statusMessage = "Nothing to copy."; return }
        guard !isExporting else { return }

        do {
            let url = try makeClipboardExportURL()
            Task { await runExport(to: url, destination: .clipboard) }
        } catch {
            statusMessage = "Couldn't prepare the clipboard copy: \(error.localizedDescription)"
        }
    }

    private func defaultExportName() -> String {
        let base = (displayName as NSString).deletingPathExtension
        let trimmed = base.split(separator: " ").first.map(String.init) ?? base
        return "\(trimmed.isEmpty ? "Untitled" : trimmed)-edited.mp4"
    }

    private enum ExportDestination {
        case file
        case clipboard
    }

    private func runExport(to url: URL, destination: ExportDestination) async {
        guard let built = buildComposition() else {
            statusMessage = "Couldn't prepare the export."
            discardClipboardStagingFileIfNeeded(at: url, destination: destination)
            return
        }
        guard let session = AVAssetExportSession(
            asset: built.composition, presetName: AVAssetExportPresetHighestQuality
        ) else {
            statusMessage = "Export isn't supported for this video."
            discardClipboardStagingFileIfNeeded(at: url, destination: destination)
            return
        }

        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = .mp4
        session.videoComposition = built.video
        session.audioTimePitchAlgorithm = .spectral

        if isPlaying { player.pause(); isPlaying = false }
        switch destination {
        case .file:
            exportProgressTitle = "Exporting MP4"
            exportProgressIcon = "square.and.arrow.up"
        case .clipboard:
            exportProgressTitle = "Copying Video"
            exportProgressIcon = "doc.on.clipboard"
        }
        isExporting = true
        exportProgress = 0
        statusMessage = nil

        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.exportProgress = Double(session.progress)
                let status = session.status
                if status == .completed || status == .failed || status == .cancelled { break }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        progressTask.cancel()

        isExporting = false
        switch session.status {
        case .completed:
            exportProgress = 1
            switch destination {
            case .file:
                statusMessage = "Exported \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .clipboard:
                if putVideoOnClipboard(url) {
                    statusMessage = "Copied video to the clipboard."
                } else {
                    discardClipboardStagingFile(at: url)
                    statusMessage = "Couldn't place the video on the clipboard."
                }
            }
        case .failed:
            discardClipboardStagingFileIfNeeded(at: url, destination: destination)
            statusMessage = "Export failed: \(session.error?.localizedDescription ?? "unknown error")"
        case .cancelled:
            discardClipboardStagingFileIfNeeded(at: url, destination: destination)
            statusMessage = "Export cancelled."
        default:
            discardClipboardStagingFileIfNeeded(at: url, destination: destination)
            statusMessage = "Export ended unexpectedly."
        }
    }

    private func makeClipboardExportURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel Clipboard", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder.appendingPathComponent(defaultExportName())
    }

    private func putVideoOnClipboard(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { return false }

        let previousURL = clipboardVideoURL
        clipboardVideoURL = url
        if let previousURL, previousURL != url {
            discardClipboardStagingFile(at: previousURL)
        }
        return true
    }

    private func discardClipboardStagingFileIfNeeded(
        at url: URL,
        destination: ExportDestination
    ) {
        if case .clipboard = destination {
            discardClipboardStagingFile(at: url)
        }
    }

    private func discardClipboardStagingFile(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
