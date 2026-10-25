import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
import ScreenCaptureKit
typealias ReelImage = NSImage
#else
import UIKit
typealias ReelImage = UIImage
#endif
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
        let encodedSize: CGSize
        let naturalSize: CGSize     // oriented (preferredTransform applied)
        let frameRate: Float
    }

    // MARK: Sources

    @Published private(set) var sourceURL: URL?       // first loaded file; nil = empty project
    @Published private(set) var hasAudio: Bool = false
    private var sources: [UUID: Source] = [:]

    /// Optional, independently editable audio lane above the video timeline.
    private var audioSources: [UUID: ImportedAudioSource] = [:]
    @Published private(set) var audioChunks: [AudioChunk] = []
    @Published private(set) var audioSelection: Set<UUID> = []
    private var importedAudioRebuildTask: Task<Void, Never>?

    var hasImportedAudioTrack: Bool { !audioChunks.isEmpty }
    var hasAnySelection: Bool { !selection.isEmpty || !audioSelection.isEmpty }
    var hasAudioSelection: Bool { !audioSelection.isEmpty }
    var selectedCount: Int { selection.count + audioSelection.count }
    var selectedAudioChunk: AudioChunk? {
        guard audioSelection.count == 1, let id = audioSelection.first else { return nil }
        return audioChunks.first { $0.id == id }
    }

    // MARK: Timeline model

    @Published var chunks: [Chunk] = []
    @Published var selection: Set<UUID> = []
    @Published private(set) var videoCrop: VideoCrop?

    var hasContent: Bool { sourceURL != nil && !chunks.isEmpty }

    /// Drops audio embedded in source videos from preview and export. The
    /// separately imported audio track deliberately remains audible.
    @Published var muteAudio: Bool = false {
        didSet { if oldValue != muteAudio { rebuild() } }
    }

    /// Slowest allowed speed. There is no upper limit - type any value you like.
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

    /// Oriented source dimensions for the single clip selected in the timeline.
    var selectedClipSizeText: String? {
        guard
            selection.count == 1,
            let id = selection.first,
            let chunk = chunks.first(where: { $0.id == id }),
            let source = sources[chunk.sourceID]
        else { return nil }

        let width = max(1, Int(source.naturalSize.width.rounded()))
        let height = max(1, Int(source.naturalSize.height.rounded()))
        return "\(width) × \(height)"
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

    private struct Snapshot {
        var chunks: [Chunk]
        var selection: Set<UUID>
        var audioSources: [UUID: ImportedAudioSource]
        var audioChunks: [AudioChunk]
        var audioSelection: Set<UUID>
        var videoCrop: VideoCrop?
    }
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

    struct ThumbFrame: Identifiable { let id = UUID(); let time: Double; let image: ReelImage }
    @Published private(set) var thumbnails: [UUID: [ThumbFrame]] = [:]
    private var thumbTasks: [UUID: Task<Void, Never>] = [:]

    #if os(iOS)
    @Published private(set) var mobileAudioTarget: MobileAudioTarget?
    @Published private(set) var mobileWaveforms: [UUID: [Float]] = [:]
    private var mobileWaveformTasks: [UUID: Task<Void, Never>] = [:]
    private var mobileWaveformQueue: Task<Void, Never>?
    @Published private(set) var isImporting = false
    @Published var exportedURL: URL?
    var mobileStorageRoot: URL?
    private var didRestoreMobileDraft = false
    private var isRestoringMobileDraft = false
    #endif

    // MARK: Export

    enum ExportAction: String, Identifiable {
        case file
        case clipboard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .file: "Export Video"
            case .clipboard: "Copy Video"
            }
        }

        var buttonTitle: String {
            switch self {
            case .file: "Continue to Save"
            case .clipboard: "Copy Video"
            }
        }

        var icon: String {
            switch self {
            case .file: "square.and.arrow.up"
            case .clipboard: "doc.on.clipboard"
            }
        }
    }

    enum ExportResolution: String, CaseIterable, Identifiable {
        case source
        case scale75
        case scale50
        case scale25
        case ultraHD
        case fullHD
        case hd
        case compact

        var id: String { rawValue }

        var title: String {
            switch self {
            case .source: "Source"
            case .scale75: "75% (0.75×)"
            case .scale50: "50% (0.5×)"
            case .scale25: "25% (0.25×)"
            case .ultraHD: "4K"
            case .fullHD: "1080p"
            case .hd: "720p"
            case .compact: "540p"
            }
        }

        fileprivate var maximumLandscapeSize: CGSize? {
            switch self {
            case .source, .scale75, .scale50, .scale25: nil
            case .ultraHD: CGSize(width: 3840, height: 2160)
            case .fullHD: CGSize(width: 1920, height: 1080)
            case .hd: CGSize(width: 1280, height: 720)
            case .compact: CGSize(width: 960, height: 540)
            }
        }

        fileprivate var scaleFactor: CGFloat? {
            switch self {
            case .scale75: 0.75
            case .scale50: 0.5
            case .scale25: 0.25
            default: nil
            }
        }
    }

    enum ExportCompression: String, CaseIterable, Identifiable {
        case compatible
        case h264Balanced
        case h264Compact
        case efficient
        case hevcBalanced
        case hevcCompact

        var id: String { rawValue }

        var title: String {
            switch self {
            case .compatible: "H.264 - High Quality"
            case .h264Balanced: "H.264 - Balanced"
            case .h264Compact: "H.264 - Smaller File"
            case .efficient: "HEVC - High Quality"
            case .hevcBalanced: "HEVC - Balanced"
            case .hevcCompact: "HEVC - Smallest File"
            }
        }

        var detail: String {
            switch self {
            case .compatible:
                "Best compatibility with the least compression."
            case .h264Balanced:
                "Good quality and compatibility with a smaller H.264 file."
            case .h264Compact:
                "More compression for sharing when compatibility matters."
            case .efficient:
                "High visual quality with more efficient HEVC compression."
            case .hevcBalanced:
                "A strong quality-to-size balance for modern apps and devices."
            case .hevcCompact:
                "The smallest files; older apps may not support HEVC."
            }
        }

        fileprivate var codec: AVVideoCodecType {
            switch self {
            case .compatible, .h264Balanced, .h264Compact: .h264
            case .efficient, .hevcBalanced, .hevcCompact: .hevc
            }
        }

        fileprivate var bitsPerPixelPerFrame: Double {
            switch self {
            case .compatible: 0.12
            case .h264Balanced: 0.075
            case .h264Compact: 0.045
            case .efficient: 0.08
            case .hevcBalanced: 0.05
            case .hevcCompact: 0.03
            }
        }

        fileprivate var audioBitRate: Int {
            switch self {
            case .compatible, .efficient: 192_000
            case .h264Balanced, .hevcBalanced: 160_000
            case .h264Compact, .hevcCompact: 128_000
            }
        }

        fileprivate func videoBitRate(for size: CGSize, frameRate: Double) -> Int {
            let pixels = max(1, Double(size.width * size.height))
            let estimate = Int(pixels * max(1, frameRate) * bitsPerPixelPerFrame)
            return min(max(estimate, 250_000), 100_000_000)
        }
    }

    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published private(set) var exportProgressTitle = "Exporting MP4"
    @Published private(set) var exportProgressIcon = "square.and.arrow.up"
    @Published var statusMessage: String?
    @Published var pendingExportAction: ExportAction?
    @Published var exportResolution: ExportResolution = ExportResolution(
        rawValue: UserDefaults.standard.string(forKey: "exportResolution") ?? ""
    ) ?? .source {
        didSet { UserDefaults.standard.set(exportResolution.rawValue, forKey: "exportResolution") }
    }
    @Published var exportCompression: ExportCompression = ExportCompression(
        rawValue: UserDefaults.standard.string(forKey: "exportCompression") ?? ""
    ) ?? .compatible {
        didSet { UserDefaults.standard.set(exportCompression.rawValue, forKey: "exportCompression") }
    }
    private var clipboardVideoURL: URL?
    private var confirmedExportAction: ExportAction?

    private let timescale: CMTimeScale = 600

    #if os(macOS)
    // MARK: Screen recording

    @Published private(set) var isPreparingRecording = false
    @Published private(set) var isSelectingCaptureRegion = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishingRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published var recordsSystemAudio = true

    private var captureSelectionCoordinator: CaptureSelectionCoordinator?
    private var screenRecorder: ScreenRecorder?
    private var recordingRegionDimmer: RecordingRegionDimmer?
    private var recordingStatusItem: RecordingStatusItemController?
    private var recordingTimer: Task<Void, Never>?
    private var stopRecordingHotKey: GlobalHotKey?
    private var concealedWindows: [NSWindow] = []

    var recordingActionDisabled: Bool {
        isPreparingRecording || isSelectingCaptureRegion || isFinishingRecording
    }

    #endif

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
        #if os(macOS)
        recordingTimer?.cancel()
        #endif
        importedAudioRebuildTask?.cancel()
        #if os(iOS)
        mobileWaveformTasks.values.forEach { $0.cancel() }
        #endif
    }

    // MARK: Loading & importing

    #if os(macOS)
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
        recordingRegionDimmer?.close()
        recordingRegionDimmer = nil
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
                let dimmer = RecordingRegionDimmer()
                dimmer.show(selection: selection)
                recordingRegionDimmer = dimmer
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
        recordingRegionDimmer?.close()
        recordingRegionDimmer = nil
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

    /// Adds or replaces the optional audio lane above the video timeline.
    func importAudioPanel() {
        guard hasContent else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = hasImportedAudioTrack ? "Replace Audio Track" : "Add Audio Track"
        if panel.runModal() == .OK, let url = panel.url {
            importAudio(url: url)
        }
    }

    private func pickVideo(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = title
        return panel.runModal() == .OK ? panel.url : nil
    }

    #endif

    func openVideo(url: URL) { Task { await loadFresh(url: url) } }
    func importVideo(url: URL) { Task { await appendImport(url: url) } }
    func importAudio(url: URL) { Task { await loadImportedAudio(url: url) } }

    private func loadImportedAudio(url: URL) async {
        let projectSourceID = chunks.first?.sourceID
        do {
            let asset = AVURLAsset(url: url)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            guard hasContent, chunks.first?.sourceID == projectSourceID else { return }
            guard let sourceTrack = sourceTracks.first else {
                statusMessage = "That file has no audio track."
                return
            }
            let duration = try await asset.load(.duration).seconds
            guard hasContent, chunks.first?.sourceID == projectSourceID else { return }
            guard duration.isFinite, duration > 0.01 else {
                statusMessage = "That audio file has no playable duration."
                return
            }

            let source = ImportedAudioSource(
                url: url,
                asset: asset,
                track: sourceTrack,
                duration: duration
            )
            let chunk = AudioChunk(
                sourceID: source.id,
                start: 0,
                end: min(duration, totalDuration)
            )
            commit {
                audioSources = [source.id: source]
                audioChunks = [chunk]
                audioSelection = [chunk.id]
                selection = []
            }
            statusMessage = "Added audio track \(url.lastPathComponent)"
            #if os(iOS)
            mobileAudioTarget = .added(chunk.id)
            #endif
        } catch {
            guard hasContent, chunks.first?.sourceID == projectSourceID else { return }
            statusMessage = "Couldn't import audio: \(error.localizedDescription)"
        }
    }

    func removeImportedAudio() {
        guard !audioChunks.isEmpty else { return }
        commit {
            audioChunks = []
            audioSelection = []
        }
        statusMessage = "Removed the imported audio track."
    }

    func audioSourceName(for sourceID: UUID) -> String {
        audioSources[sourceID]?.url.lastPathComponent ?? "Audio"
    }

    func setSelectedAudioVolume(_ value: Double) {
        updateSelectedAudioMix { $0.volume = Float(value) }
    }

    func setSelectedAudioFadeIn(_ value: Double) {
        updateSelectedAudioMix { $0.fadeInDuration = value }
    }

    func setSelectedAudioFadeOut(_ value: Double) {
        updateSelectedAudioMix { $0.fadeOutDuration = value }
    }

    var maxSelectedAudioFadeDuration: Double {
        (selectedAudioChunk?.outputDuration ?? 0) / 2
    }

    private func updateSelectedAudioMix(_ action: (inout AudioChunk) -> Void) {
        guard audioSelection.count == 1,
              let id = audioSelection.first,
              let index = audioChunks.firstIndex(where: { $0.id == id })
        else { return }
        action(&audioChunks[index])
        normalizeAudioChunk(&audioChunks[index])
        scheduleImportedAudioRebuild()
    }

    /// Slider drags can publish dozens of values per second. Coalescing those
    /// changes keeps the compact lane inspector fluid while updating preview
    /// as soon as the pointer pauses; export always reads the latest model.
    private func scheduleImportedAudioRebuild() {
        importedAudioRebuildTask?.cancel()
        importedAudioRebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled, let self else { return }
            self.rebuild()
            self.importedAudioRebuildTask = nil
        }
    }

    private func makeSource(url: URL) async throws -> Source? {
        let asset = AVURLAsset(url: url)
        async let loadedVideoTracks = asset.loadTracks(withMediaType: .video)
        async let loadedAudioTracks = asset.loadTracks(withMediaType: .audio)
        async let loadedDuration = asset.load(.duration)
        let (videoTracks, audioTracks, duration) = try await (loadedVideoTracks, loadedAudioTracks, loadedDuration)
        guard let video = videoTracks.first else { return nil }
        async let loadedTransform = video.load(.preferredTransform)
        async let loadedSize = video.load(.naturalSize)
        async let loadedFrameRate = try? video.load(.nominalFrameRate)
        let (transform, size) = try await (loadedTransform, loadedSize)
        let fps = await loadedFrameRate ?? 30
        let oriented = size.applying(transform)
        return Source(
            id: UUID(), url: url, asset: asset, videoTrack: video, audioTrack: audioTracks.first,
            duration: duration.seconds, preferredTransform: transform,
            encodedSize: size,
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
            importedAudioRebuildTask?.cancel()
            audioSources = [:]
            audioChunks = []
            audioSelection = []
            videoCrop = nil
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
                audioSelection = []
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
    private func buildComposition(outputResolution: ExportResolution = .source) -> (
        composition: AVMutableComposition,
        video: AVMutableVideoComposition,
        audioMix: AVAudioMix?
    )? {
        guard let first = chunks.first, let firstSource = sources[first.sourceID] else { return nil }
        let comp = AVMutableComposition()
        guard let compVideo = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        let needsAudio = !muteAudio && chunks.contains { sources[$0.sourceID]?.audioTrack != nil }
        let compAudio = needsAudio
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil
        let embeddedMix = compAudio.map { AVMutableAudioMixInputParameters(track: $0) }

        let crop = resolvedVideoCrop
        let renderSize = exportSize(for: crop.outputSize, resolution: outputResolution)
        var cursor = CMTime.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var embeddedSpans: [AudioGainEnvelope.Span] = []

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
            for section in chunk.visibleAudioSections {
                let lower = max(0, min(segmentDuration.seconds, (section.start - chunk.start) / chunk.speed))
                let upper = section.end == chunk.end ? segmentDuration.seconds
                    : max(lower, min(segmentDuration.seconds, (section.end - chunk.start) / chunk.speed))
                embeddedSpans.append(.init(start: segmentStart.seconds + lower,
                                           duration: upper - lower,
                                           volume: source.audioTrack == nil ? 0 : max(0, min(1, section.volume)),
                                           fades: section.fades == true))
            }
            instruction.timeRange = CMTimeRange(start: segmentStart, duration: segmentDuration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            layer.setTransform(VideoGeometry.transform(encodedSize: source.encodedSize, preferred: source.preferredTransform,
                                                       crop: crop, framing: chunk.framing ?? ClipFraming(), outputSize: renderSize),
                               at: segmentStart)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)

            cursor = segmentStart + segmentDuration
        }

        if let embeddedMix {
            for index in embeddedSpans.indices {
                AudioGainEnvelope.ramps(at: index, in: embeddedSpans).forEach { $0.apply(to: embeddedMix) }
            }
        }
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        let fps = max(24, min(60, Double(firstSource.frameRate)))
        videoComp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        videoComp.instructions = instructions

        // Audio-lane clips use independent composition tracks. They can be cut,
        // moved, overlapped and re-timed without ever consulting `muteAudio`.
        let timelineDuration = cursor.seconds
        var mixParameters: [AVAudioMixInputParameters] = embeddedMix.map { [$0] } ?? []
        let sortedAudio = audioChunks.sorted(by: { $0.timelineStart < $1.timelineStart })
        let addedSpans = sortedAudio.map {
            AudioGainEnvelope.Span(start: $0.timelineStart, duration: min($0.outputDuration, max(0, timelineDuration - $0.timelineStart)),
                                   volume: max(0, min(2, $0.volume)), fades: $0.smoothTransitions == true)
        }
        for (audioIndex, audio) in sortedAudio.enumerated() {
            guard let source = audioSources[audio.sourceID], audio.speed > 0 else { continue }
            let placementStart = max(0, min(audio.timelineStart, timelineDuration))
            let placedDuration = max(0, min(audio.outputDuration, timelineDuration - placementStart))
            let sourceDuration = min(audio.sourceDuration, placedDuration * audio.speed)
            guard placedDuration > 0.001, sourceDuration > 0.001,
                  let compositionAudio = comp.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { continue }

            let destinationStart = CMTime(seconds: placementStart, preferredTimescale: timescale)
            let sourceTime = CMTime(seconds: audio.start, preferredTimescale: timescale)
            let sourceTimeDuration = CMTime(seconds: sourceDuration, preferredTimescale: timescale)
            do {
                try compositionAudio.insertTimeRange(
                    CMTimeRange(start: sourceTime, duration: sourceTimeDuration),
                    of: source.track,
                    at: destinationStart
                )
            } catch {
                continue
            }

            if audio.speed != 1 {
                compositionAudio.scaleTimeRange(
                    CMTimeRange(start: destinationStart, duration: sourceTimeDuration),
                    toDuration: CMTime(seconds: placedDuration, preferredTimescale: timescale)
                )
            }

            let volume = max(0, min(audio.volume, 2))
            let fadeIn = min(max(0, audio.fadeInDuration), placedDuration / 2)
            let fadeOut = min(max(0, audio.fadeOutDuration), placedDuration / 2)
            let parameters = AVMutableAudioMixInputParameters(track: compositionAudio)

            if addedSpans.contains(where: \.fades) {
                AudioGainEnvelope.ramps(at: audioIndex, in: addedSpans).forEach { $0.apply(to: parameters) }
            } else {
                if fadeIn > 0 {
                    parameters.setVolumeRamp(
                        fromStartVolume: 0,
                        toEndVolume: volume,
                        timeRange: CMTimeRange(
                            start: destinationStart,
                            duration: CMTime(seconds: fadeIn, preferredTimescale: timescale)
                        )
                    )
                } else {
                    parameters.setVolume(volume, at: destinationStart)
                }

                if fadeOut > 0 {
                    let fadeOutStart = CMTime(
                        seconds: placementStart + placedDuration - fadeOut,
                        preferredTimescale: timescale
                    )
                    parameters.setVolumeRamp(
                        fromStartVolume: volume,
                        toEndVolume: 0,
                        timeRange: CMTimeRange(
                            start: fadeOutStart,
                            duration: CMTime(seconds: fadeOut, preferredTimescale: timescale)
                        )
                    )
                }
            }
            mixParameters.append(parameters)
        }

        let audioMix: AVMutableAudioMix? = mixParameters.isEmpty ? nil : {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParameters
            return mix
        }()

        return (comp, videoComp, audioMix)
    }

    var resolvedVideoCrop: VideoCrop {
        if let videoCrop { return videoCrop.clamped }
        let size = chunks.first.flatMap { sources[$0.sourceID]?.naturalSize } ?? CGSize(width: 1080, height: 1920)
        return VideoCrop(canvasWidth: size.width, canvasHeight: size.height)
    }

    func setVideoCrop(_ crop: VideoCrop) {
        let next = crop.clamped
        guard videoCrop != next else { return }
        commit { videoCrop = next }
    }

    func setClipFraming(_ framing: ClipFraming, for id: UUID) {
        guard let index = chunks.firstIndex(where: { $0.id == id }) else { return }
        let next = framing.clamped
        guard (chunks[index].framing ?? ClipFraming()) != next else { return }
        commit {
            if videoCrop == nil { videoCrop = resolvedVideoCrop }
            chunks[index].framing = next
        }
    }

    private func evenSize(_ size: CGSize) -> CGSize {
        let w = max(2, (Int(size.width.rounded()) / 2) * 2)
        let h = max(2, (Int(size.height.rounded()) / 2) * 2)
        return CGSize(width: w, height: h)
    }

    private func exportSize(for sourceSize: CGSize, resolution: ExportResolution) -> CGSize {
        let source = evenSize(sourceSize)
        if let scaleFactor = resolution.scaleFactor {
            return evenSize(
                CGSize(width: source.width * scaleFactor, height: source.height * scaleFactor)
            )
        }
        guard let landscapeMaximum = resolution.maximumLandscapeSize else { return source }

        let maximum = source.width >= source.height
            ? landscapeMaximum
            : CGSize(width: landscapeMaximum.height, height: landscapeMaximum.width)
        let scale = min(1, maximum.width / source.width, maximum.height / source.height)
        return evenSize(CGSize(width: source.width * scale, height: source.height * scale))
    }

    private func rebuild(seekTo time: Double? = nil) {
        #if os(iOS)
        defer { saveMobileDraft() }
        #endif
        totalDuration = chunks.reduce(0) { $0 + $1.outputDuration }
        guard let built = buildComposition(), totalDuration > 0 else {
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        #if os(macOS)
        item.videoComposition = built.video
        #endif
        // Mobile playback uses the same timeline and audio mix. Its player layer
        // applies the source transform and aspect fit without a video compositor.
        // This also avoids composition-backed video-compositor playback failures
        // reproduced on iOS 27, while export still uses the full video composition.
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        seek(to: time ?? min(currentTime, totalDuration))
        if isPlaying { player.play() }
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

    private func snapshot() -> Snapshot {
        Snapshot(
            chunks: chunks,
            selection: selection,
            audioSources: audioSources,
            audioChunks: audioChunks,
            audioSelection: audioSelection,
            videoCrop: videoCrop
        )
    }

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

    private func selectedAudioChunkAtPlayhead() -> (index: Int, local: Double)? {
        guard audioSelection.count == 1, let id = audioSelection.first,
              let index = audioChunks.firstIndex(where: { $0.id == id })
        else { return nil }
        let chunk = audioChunks[index]
        let local = currentTime - chunk.timelineStart
        guard local >= -1e-6, local < chunk.outputDuration - 1e-6 else { return nil }
        return (index, max(0, local))
    }

    func splitAtPlayhead() {
        if let (index, local) = selectedAudioChunkAtPlayhead() {
            let chunk = audioChunks[index]
            guard local > 0.02, local < chunk.outputDuration - 0.02 else { return }
            let sourceSplit = chunk.start + local * chunk.speed
            let secondID = UUID()
            commit {
                var first = chunk
                first.end = sourceSplit
                first.fadeOutDuration = 0
                var second = AudioChunk(
                    id: secondID,
                    sourceID: chunk.sourceID,
                    start: sourceSplit,
                    end: chunk.end,
                    timelineStart: currentTime,
                    speed: chunk.speed,
                    volume: chunk.volume,
                    fadeInDuration: 0,
                    fadeOutDuration: chunk.fadeOutDuration
                )
                second.smoothTransitions = chunk.smoothTransitions
                normalizeAudioChunk(&first)
                normalizeAudioChunk(&second)
                audioChunks.replaceSubrange(index...index, with: [first, second])
                audioSelection = [second.id]
            }
            #if os(iOS)
            mobileAudioTarget = .added(secondID)
            #endif
            return
        }

        guard let (index, local, _) = chunkAtPlayhead() else { return }
        let chunk = chunks[index]
        if local <= 0.02 || local >= chunk.outputDuration - 0.02 { return }
        let sourceSplit = chunk.start + local * chunk.speed
        commit {
            let first = Chunk(id: chunk.id, sourceID: chunk.sourceID, start: chunk.start, end: sourceSplit,
                              speed: chunk.speed, audioSections: chunk.audioSections, framing: chunk.framing)
            let second = Chunk(sourceID: chunk.sourceID, start: sourceSplit, end: chunk.end,
                               speed: chunk.speed, audioSections: chunk.audioSections, framing: chunk.framing)
            chunks.replaceSubrange(index...index, with: [first, second])
            selection = [second.id]
        }
    }

    func deleteBeforePlayhead() {
        if let (index, local) = selectedAudioChunkAtPlayhead() {
            guard local > 0.02 else { return }
            commit {
                audioChunks[index].start += local * audioChunks[index].speed
                audioChunks[index].timelineStart = currentTime
                normalizeAudioChunk(&audioChunks[index])
                audioSelection = [audioChunks[index].id]
            }
            return
        }

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
        if let (index, local) = selectedAudioChunkAtPlayhead() {
            let chunk = audioChunks[index]
            guard local < chunk.outputDuration - 0.02 else { return }
            commit {
                audioChunks[index].end = chunk.start + local * chunk.speed
                normalizeAudioChunk(&audioChunks[index])
                audioSelection = [audioChunks[index].id]
            }
            return
        }

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
        if !audioSelection.isEmpty {
            commit {
                audioChunks.removeAll { audioSelection.contains($0.id) }
                audioSelection = []
            }
            return
        }
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

    /// Removes the entire project after the view has obtained confirmation.
    /// This deliberately resets history so the destructive action cannot be
    /// accidentally undone into a project the user explicitly cleared.
    func clearAll() {
        guard sourceURL != nil || !chunks.isEmpty else { return }

        player.pause()
        isPlaying = false
        thumbTasks.values.forEach { $0.cancel() }
        thumbTasks.removeAll()
        #if os(iOS)
        mobileWaveformTasks.values.forEach { $0.cancel() }
        mobileWaveformTasks.removeAll()
        mobileWaveformQueue = nil
        mobileWaveforms = [:]
        mobileAudioTarget = nil
        #endif

        sources.removeAll()
        videoCrop = nil
        chunks = []
        selection = []
        audioSources.removeAll()
        audioChunks = []
        audioSelection = []
        importedAudioRebuildTask?.cancel()
        sourceURL = nil
        hasAudio = false
        thumbnails = [:]
        past = []
        future = []
        pps = nil
        currentTime = 0
        totalDuration = 0
        statusMessage = nil
        player.replaceCurrentItem(with: nil)

        if muteAudio {
            muteAudio = false
        }
        #if os(iOS)
        saveMobileDraft()
        #endif
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
        #if os(iOS)
        mobileAudioTarget = nil
        #endif
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        selection = [id]
        audioSelection = []
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

    // MARK: Audio-lane trimming and placement

    func beginAudioTrimPreview(_ id: UUID) {
        guard audioChunks.contains(where: { $0.id == id }) else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        audioSelection = [id]
        selection = []
    }

    func audioTrimPreview(
        from original: AudioChunk,
        edge: TrimEdge,
        sourceDelta: Double
    ) -> AudioChunk {
        guard audioChunks.contains(where: { $0.id == original.id }),
              let source = audioSources[original.sourceID],
              original.speed > 0
        else { return original }

        let minimumDuration = min(source.duration, 0.02)
        var updated = original
        switch edge {
        case .leading:
            let earliestSource = max(0, original.start - original.timelineStart * original.speed)
            let nextStart = min(
                max(earliestSource, original.start + sourceDelta),
                original.end - minimumDuration
            )
            updated.start = nextStart
            updated.timelineStart = original.timelineStart
                + (nextStart - original.start) / original.speed
        case .trailing:
            let latestSource = min(
                source.duration,
                original.start + max(0, totalDuration - original.timelineStart) * original.speed
            )
            updated.end = max(
                original.start + minimumDuration,
                min(latestSource, original.end + sourceDelta)
            )
        }
        normalizeAudioChunk(&updated)
        return updated
    }

    @discardableResult
    func commitAudioTrimPreview(_ preview: AudioChunk) -> Bool {
        guard let index = audioChunks.firstIndex(where: { $0.id == preview.id }),
              audioChunks[index] != preview,
              audioChunks[index].sourceID == preview.sourceID
        else { return false }
        commit {
            audioChunks[index] = preview
            audioSelection = [preview.id]
            selection = []
        }
        return true
    }

    func canRestoreAudioTrim(_ id: UUID, edge: TrimEdge) -> Bool {
        guard let chunk = audioChunks.first(where: { $0.id == id }),
              let source = audioSources[chunk.sourceID]
        else { return false }
        switch edge {
        case .leading:
            return min(chunk.start, chunk.timelineStart * chunk.speed) > 0.001
        case .trailing:
            let latestSource = min(
                source.duration,
                chunk.start + max(0, totalDuration - chunk.timelineStart) * chunk.speed
            )
            return latestSource - chunk.end > 0.001
        }
    }

    func restoreAudioTrim(_ id: UUID, edge: TrimEdge) {
        guard let index = audioChunks.firstIndex(where: { $0.id == id }),
              let source = audioSources[audioChunks[index].sourceID],
              canRestoreAudioTrim(id, edge: edge)
        else { return }
        commit {
            switch edge {
            case .leading:
                let recoverable = min(
                    audioChunks[index].start,
                    audioChunks[index].timelineStart * audioChunks[index].speed
                )
                audioChunks[index].start -= recoverable
                audioChunks[index].timelineStart -= recoverable / audioChunks[index].speed
            case .trailing:
                audioChunks[index].end = min(
                    source.duration,
                    audioChunks[index].start
                        + max(0, totalDuration - audioChunks[index].timelineStart)
                        * audioChunks[index].speed
                )
            }
            normalizeAudioChunk(&audioChunks[index])
            audioSelection = [id]
            selection = []
        }
    }

    func audioMovePreview(from original: AudioChunk, outputDelta: Double) -> AudioChunk {
        var updated = original
        updated.timelineStart = original.timelineStart + outputDelta
        normalizeAudioChunk(&updated)
        return updated
    }

    @discardableResult
    func commitAudioMovePreview(_ preview: AudioChunk) -> Bool {
        guard let index = audioChunks.firstIndex(where: { $0.id == preview.id }),
              audioChunks[index] != preview,
              audioChunks[index].sourceID == preview.sourceID
        else { return false }
        commit {
            audioChunks[index] = preview
            audioSelection = [preview.id]
            selection = []
        }
        return true
    }

    private func normalizeAudioChunk(_ chunk: inout AudioChunk) {
        guard let source = audioSources[chunk.sourceID] else { return }
        chunk.speed = max(Self.minSpeed, chunk.speed)
        let minimumDuration = min(source.duration, 0.02)
        chunk.start = max(0, min(chunk.start, source.duration - minimumDuration))
        chunk.end = max(chunk.start + minimumDuration, min(chunk.end, source.duration))
        let maxStart = max(0, totalDuration - chunk.outputDuration)
        chunk.timelineStart = max(0, min(chunk.timelineStart, maxStart))
        chunk.volume = max(0, min(chunk.volume, 2))
        let maxFade = chunk.outputDuration / 2
        chunk.fadeInDuration = max(0, min(chunk.fadeInDuration, maxFade))
        chunk.fadeOutDuration = max(0, min(chunk.fadeOutDuration, maxFade))
    }

    /// Applies a speed to the selected chunks, or to every chunk when `all`.
    func setSpeed(_ speed: Double, all: Bool = false) {
        guard speed.isFinite, speed > 0 else { return }
        let clamped = max(speed, Self.minSpeed)
        if !audioSelection.isEmpty {
            let targets = all ? Set(audioChunks.map(\.id)) : audioSelection
            let needsChange = audioChunks.contains {
                targets.contains($0.id) && $0.speed != clamped
            }
            guard needsChange else { return }
            commit {
                for index in audioChunks.indices where targets.contains(audioChunks[index].id) {
                    audioChunks[index].speed = clamped
                    normalizeAudioChunk(&audioChunks[index])
                }
            }
            return
        }
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

    private var singleSelectedAudioIndex: Int? {
        guard audioSelection.count == 1, let id = audioSelection.first else { return nil }
        return audioChunks.firstIndex { $0.id == id }
    }

    var canMoveBackward: Bool {
        if let i = singleSelectedAudioIndex { return audioChunks[i].timelineStart > 0.001 }
        if let i = singleSelectedIndex { return i > 0 }
        return false
    }
    var canMoveForward: Bool {
        if let i = singleSelectedAudioIndex { return audioChunks[i].timelineEnd < totalDuration - 0.001 }
        if let i = singleSelectedIndex { return i < chunks.count - 1 }
        return false
    }

    /// Moves the single selected clip one slot earlier (-1) or later (+1).
    func moveSelected(by offset: Int) {
        if let index = singleSelectedAudioIndex {
            commit {
                audioChunks[index].timelineStart += Double(offset) * 0.25
                normalizeAudioChunk(&audioChunks[index])
            }
            return
        }
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
            audioSelection = []
            return true
        }

        commit {
            let moved = chunks.remove(at: sourceIndex)
            chunks.insert(moved, at: min(max(0, insertionIndex), chunks.count))
            selection = [id]
            audioSelection = []
        }
        return true
    }

    // MARK: Undo / redo

    func undo() {
        guard let snap = past.popLast() else { return }
        future.append(snapshot())
        chunks = snap.chunks
        selection = snap.selection
        audioSources = snap.audioSources
        audioChunks = snap.audioChunks
        audioSelection = snap.audioSelection
        videoCrop = snap.videoCrop
        rebuild()
    }

    func redo() {
        guard let snap = future.popLast() else { return }
        past.append(snapshot())
        chunks = snap.chunks
        selection = snap.selection
        audioSources = snap.audioSources
        audioChunks = snap.audioChunks
        audioSelection = snap.audioSelection
        videoCrop = snap.videoCrop
        rebuild()
    }

    // MARK: Selection

    func select(_ id: UUID, additive: Bool) {
        #if os(iOS)
        mobileAudioTarget = nil
        #endif
        if additive {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        audioSelection = []
    }

    func selectAudio(_ id: UUID) {
        guard audioChunks.contains(where: { $0.id == id }) else { return }
        #if os(iOS)
        mobileAudioTarget = .added(id)
        #endif
        audioSelection = [id]
        selection = []
    }

    func clearSelection() {
        selection = []
        audioSelection = []
    }

    /// A representative speed for the current selection (or whole timeline).
    var activeSpeed: Double? {
        if !audioSelection.isEmpty {
            let speeds = Set(
                audioChunks.filter { audioSelection.contains($0.id) }.map(\.speed)
            )
            return speeds.count == 1 ? speeds.first : nil
        }
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
        #if os(iOS)
        generator.maximumSize = CGSize(width: 192, height: 192)
        #else
        generator.maximumSize = CGSize(width: 320, height: 320)
        #endif
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: timescale)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: timescale)

        #if os(iOS)
        let count = min(24, max(6, Int(source.duration / 5)))
        #else
        let count = min(120, max(10, Int(source.duration)))
        #endif
        let step = source.duration / Double(count)
        let times = (0..<count).map {
            CMTime(seconds: (Double($0) + 0.5) * step, preferredTimescale: timescale)
        }
        let sid = source.id

        thumbTasks[sid] = Task { [weak self] in
            for await frame in generator.images(for: times) {
                if Task.isCancelled { return }
                guard let cg = try? frame.image else { continue }
#if os(macOS)
                let image = NSImage(cgImage: cg, size: .zero)
#else
                let image = UIImage(cgImage: cg)
#endif
                let time = frame.requestedTime.seconds
                self?.thumbnails[sid, default: []].append(ThumbFrame(time: time, image: image))
                self?.thumbnails[sid]?.sort { $0.time < $1.time }
            }
        }
    }

    /// Nearest cached thumbnail in a source to a given source time.
    func thumbnail(sourceID: UUID, near time: Double) -> ReelImage? {
        guard let frames = thumbnails[sourceID], !frames.isEmpty else { return nil }
        var best: ReelImage?
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
        pendingExportAction = .file
    }

    func copyVideo() {
        guard hasContent else { statusMessage = "Nothing to copy."; return }
        guard !isExporting else { return }
        pendingExportAction = .clipboard
    }

    func confirmExportOptions(
        for action: ExportAction,
        resolution: ExportResolution,
        compression: ExportCompression
    ) {
        guard pendingExportAction == action else { return }
        exportResolution = resolution
        exportCompression = compression
        confirmedExportAction = action
        pendingExportAction = nil
    }

    func cancelExportOptions() {
        confirmedExportAction = nil
        pendingExportAction = nil
    }

    /// Called after the settings sheet has fully closed so its Save panel does
    /// not compete with SwiftUI's sheet dismissal animation.
    func performConfirmedExportIfNeeded() {
        guard let action = confirmedExportAction else { return }
        confirmedExportAction = nil
        let resolution = exportResolution
        let compression = exportCompression

        #if os(macOS)
        switch action {
        case .file:
            chooseExportDestination(resolution: resolution, compression: compression)
        case .clipboard:
            prepareClipboardExport(resolution: resolution, compression: compression)
        }
        #else
        exportMobile()
        #endif
    }

    func exportDimensions(for resolution: ExportResolution) -> String {
        guard let first = chunks.first, let source = sources[first.sourceID] else { return "-" }
        let size = exportSize(for: resolvedVideoCrop.outputSize, resolution: resolution)
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    #if os(macOS)
    private func chooseExportDestination(
        resolution: ExportResolution,
        compression: ExportCompression
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = defaultExportName()
        panel.canCreateDirectories = true
        panel.title = "Export Video"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await runExport(
                to: url,
                destination: .file,
                resolution: resolution,
                compression: compression
            )
        }
    }

    private func prepareClipboardExport(
        resolution: ExportResolution,
        compression: ExportCompression
    ) {
        do {
            let url = try makeClipboardExportURL()
            Task {
                await runExport(
                    to: url,
                    destination: .clipboard,
                    resolution: resolution,
                    compression: compression
                )
            }
        } catch {
            statusMessage = "Couldn't prepare the clipboard copy: \(error.localizedDescription)"
        }
    }

    #endif

    private func defaultExportName() -> String {
        let base = (displayName as NSString).deletingPathExtension
        let trimmed = base.split(separator: " ").first.map(String.init) ?? base
        return "\(trimmed.isEmpty ? "Untitled" : trimmed)-edited.mp4"
    }

    private func runExport(
        to url: URL,
        destination: ExportAction,
        resolution: ExportResolution,
        compression: ExportCompression
    ) async {
        guard let built = buildComposition(outputResolution: resolution) else {
            statusMessage = "Couldn't prepare the export."
            discardClipboardStagingFileIfNeeded(at: url, destination: destination)
            return
        }

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

        let frameRate = 1 / max(built.video.frameDuration.seconds, 1.0 / 120.0)
        let videoBitRate = compression.videoBitRate(
            for: built.video.renderSize,
            frameRate: frameRate
        )

        do {
            try await VideoExporter.export(
                asset: built.composition,
                videoComposition: built.video,
                audioMix: built.audioMix,
                outputURL: url,
                codec: compression.codec,
                averageVideoBitRate: videoBitRate,
                averageAudioBitRate: compression.audioBitRate,
                frameRate: frameRate
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isExporting else { return }
                    self.exportProgress = progress
                }
            }

            isExporting = false
            exportProgress = 1
            switch destination {
            case .file:
                statusMessage = "Exported \(url.lastPathComponent)"
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                #else
                exportedURL = url
                #endif
            case .clipboard:
                if putVideoOnClipboard(url) {
                    statusMessage = "Copied video to the clipboard."
                } else {
                    discardClipboardStagingFile(at: url)
                    statusMessage = "Couldn't place the video on the clipboard."
                }
            }
        } catch {
            isExporting = false
            try? FileManager.default.removeItem(at: url)
            discardClipboardStagingFileIfNeeded(at: url, destination: destination)
            statusMessage = "Export failed: \(error.localizedDescription)"
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

    #if os(macOS)
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

    #else
    private func putVideoOnClipboard(_ url: URL) -> Bool { false }
    #endif

    private func discardClipboardStagingFileIfNeeded(
        at url: URL,
        destination: ExportAction
    ) {
        if case .clipboard = destination {
            discardClipboardStagingFile(at: url)
        }
    }

    private func discardClipboardStagingFile(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

#if os(iOS)
struct MobilePreviewGeometry {
    let encodedSize: CGSize
    let outputSize: CGSize
    let transform: CGAffineTransform
}

private struct MobileDraft: Codable {
    struct Media: Codable {
        let id: UUID
        let path: String
    }
    let version: Int
    let videos: [Media]
    let audio: [Media]
    let chunks: [Chunk]
    let audioChunks: [AudioChunk]
    let muted: Bool
    var crop: VideoCrop?
}

extension EditorViewModel {
    var mobileVideoAudioSegments: [MobileAudioSegment] {
        var cursor = 0.0
        return chunks.flatMap { chunk -> [MobileAudioSegment] in
            defer { cursor += chunk.outputDuration }
            return chunk.visibleAudioSections.map { section in
                MobileAudioSegment(target: .video(chunkID: chunk.id, sectionID: section.id),
                                   sourceID: chunk.sourceID, start: section.start, end: section.end,
                                   timelineStart: cursor + (section.start - chunk.start) / chunk.speed,
                                   duration: (section.end - section.start) / chunk.speed,
                                   sourceDuration: sources[chunk.sourceID]?.duration ?? chunk.end,
                                   volume: muteAudio ? 0 : section.volume,
                                   hasAudio: sources[chunk.sourceID]?.audioTrack != nil, fades: section.fades == true)
            }
        }
    }

    var mobileAddedAudioSegments: [MobileAudioSegment] {
        audioChunks.map { audio in
            MobileAudioSegment(target: .added(audio.id), sourceID: audio.sourceID,
                               start: audio.start, end: audio.end, timelineStart: audio.timelineStart,
                               duration: min(audio.outputDuration, max(0, totalDuration - audio.timelineStart)),
                               sourceDuration: audioSources[audio.sourceID]?.duration ?? audio.end,
                               volume: audio.volume, hasAudio: true, fades: audio.smoothTransitions == true)
        }
    }

    var selectedMobileAudioSegment: MobileAudioSegment? {
        (mobileVideoAudioSegments + mobileAddedAudioSegments).first { $0.target == mobileAudioTarget }
    }

    var mobileSourceAudioSelected: Bool {
        if case .video = mobileAudioTarget { return selectedMobileAudioSegment != nil }
        return false
    }

    func selectMobileAudio(_ target: MobileAudioTarget?) {
        mobileAudioTarget = target
        clearSelection()
        beginScrub()
        endScrub()
        if case .added(let id) = target { audioSelection = [id] }
    }

    func selectMobileAudioAtPlayhead() {
        let segment = mobileVideoAudioSegments.first {
            $0.hasAudio && currentTime >= $0.timelineStart && currentTime < $0.timelineStart + $0.duration
        } ?? mobileAddedAudioSegments.first
        selectMobileAudio(segment?.target)
    }

    func splitMobileAudioAtPlayhead() {
        guard let (index, local, _) = chunkAtPlayhead(), sources[chunks[index].sourceID]?.audioTrack != nil else { return }
        let chunk = chunks[index]
        let sourceTime = chunk.start + local * chunk.speed
        var sections = chunk.audioSections ?? [ClipAudioSection(id: chunk.id, start: 0,
                                                                 end: sources[chunk.sourceID]?.duration ?? chunk.end)]
        guard let sectionIndex = sections.firstIndex(where: {
            sourceTime > max(chunk.start, $0.start) + 0.02 * chunk.speed &&
            sourceTime < min(chunk.end, $0.end) - 0.02 * chunk.speed
        }) else { return }
        let original = sections[sectionIndex]
        var first = original
        first.end = sourceTime
        let second = ClipAudioSection(start: sourceTime, end: original.end, volume: original.volume, fades: original.fades)
        sections.replaceSubrange(sectionIndex...sectionIndex, with: [first, second])
        commit { chunks[index].audioSections = sections }
        selectMobileAudio(.video(chunkID: chunk.id, sectionID: second.id))
    }

    func setMobileAudioVolume(_ value: Double) {
        guard value.isFinite, let target = mobileAudioTarget else { return }
        let volume = Float(max(0, min(1, value)))
        switch target {
        case .video(let chunkID, let sectionID):
            guard let index = chunks.firstIndex(where: { $0.id == chunkID }) else { return }
            var sections = chunks[index].audioSections ?? [ClipAudioSection(id: chunkID, start: 0,
                end: sources[chunks[index].sourceID]?.duration ?? chunks[index].end)]
            guard let section = sections.firstIndex(where: { $0.id == sectionID }),
                  sections[section].volume != volume || muteAudio else { return }
            sections[section].volume = volume
            commit { chunks[index].audioSections = sections }
            // Existing drafts can have a global video mute. Keep that explicit
            // until the user restores original sound with the button in the lane.
        case .added(let id):
            guard let index = audioChunks.firstIndex(where: { $0.id == id }), audioChunks[index].volume != volume else { return }
            commit { audioChunks[index].volume = volume }
        }
    }

    func setMobileAudioFade(_ enabled: Bool) {
        guard let target = mobileAudioTarget else { return }
        switch target {
        case .video(let chunkID, let sectionID):
            guard let index = chunks.firstIndex(where: { $0.id == chunkID }) else { return }
            var sections = chunks[index].audioSections ?? [ClipAudioSection(id: chunkID, start: 0,
                end: sources[chunks[index].sourceID]?.duration ?? chunks[index].end)]
            guard let section = sections.firstIndex(where: { $0.id == sectionID }),
                  (sections[section].fades == true) != enabled else { return }
            sections[section].fades = enabled
            commit { chunks[index].audioSections = sections }
        case .added(let id):
            guard let index = audioChunks.firstIndex(where: { $0.id == id }),
                  (audioChunks[index].smoothTransitions == true) != enabled else { return }
            commit { audioChunks[index].smoothTransitions = enabled }
        }
    }

    func prepareMobileWaveforms() {
        let media = sources.values.filter { $0.audioTrack != nil }.map { ($0.id, $0.url, $0.duration) }
            + audioSources.values.map { ($0.id, $0.url, $0.duration) }
        for (id, url, duration) in media where mobileWaveforms[id] == nil && mobileWaveformTasks[id] == nil {
            let predecessor = mobileWaveformQueue
            let task = Task { [weak self] in
                await predecessor?.value
                guard !Task.isCancelled else { return }
                let worker = Task.detached(priority: .utility) { try await AudioWaveform.read(url: url, duration: duration) }
                let peaks = await withTaskCancellationHandler {
                    try? await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self else { return }
                if self.sources[id] != nil || self.audioSources[id] != nil { self.mobileWaveforms[id] = peaks ?? [] }
                self.mobileWaveformTasks[id] = nil
            }
            mobileWaveformTasks[id] = task
            mobileWaveformQueue = task
        }
    }

    private var mobileDocuments: URL {
        mobileStorageRoot ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var mobileDraftURL: URL {
        mobileDocuments.appendingPathComponent("Reel-draft.json")
    }

    func saveMobileDraft() {
        guard !isRestoringMobileDraft else { return }
        do {
            let root = mobileDocuments.path + "/"
            let draft = MobileDraft(
                version: 1,
                videos: sources.values.map {
                    .init(id: $0.id, path: String($0.url.path.dropFirst(root.count)))
                },
                audio: audioSources.values.map {
                    .init(id: $0.id, path: String($0.url.path.dropFirst(root.count)))
                },
                chunks: chunks,
                audioChunks: audioChunks,
                muted: muteAudio,
                crop: videoCrop
            )
            try JSONEncoder().encode(draft).write(to: mobileDraftURL, options: .atomic)
        } catch {
            statusMessage = "Couldn't save your draft: \(error.localizedDescription)"
        }
    }

    func restoreMobileDraft() async {
        guard !didRestoreMobileDraft else { return }
        didRestoreMobileDraft = true
        guard FileManager.default.fileExists(atPath: mobileDraftURL.path) else { return }
        isImporting = true
        isRestoringMobileDraft = true
        defer { isImporting = false; isRestoringMobileDraft = false }
        do {
            let draft = try JSONDecoder().decode(MobileDraft.self, from: Data(contentsOf: mobileDraftURL))
            guard draft.version == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var restored: [UUID: Source] = [:]
            for media in draft.videos {
                let url = mobileDocuments.appendingPathComponent(media.path)
                guard let source = try await makeSource(url: url) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                restored[media.id] = Source(
                    id: media.id, url: url, asset: source.asset,
                    videoTrack: source.videoTrack, audioTrack: source.audioTrack,
                    duration: source.duration, preferredTransform: source.preferredTransform,
                    encodedSize: source.encodedSize, naturalSize: source.naturalSize, frameRate: source.frameRate
                )
            }
            var restoredAudio: [UUID: ImportedAudioSource] = [:]
            for media in draft.audio {
                let url = mobileDocuments.appendingPathComponent(media.path)
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let duration = try await asset.load(.duration).seconds
                restoredAudio[media.id] = ImportedAudioSource(
                    id: media.id, url: url, asset: asset, track: track, duration: duration
                )
            }
            guard draft.chunks.allSatisfy({ restored[$0.sourceID] != nil }),
                  draft.audioChunks.allSatisfy({ restoredAudio[$0.sourceID] != nil }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            sources = restored
            audioSources = restoredAudio
            chunks = draft.chunks
            audioChunks = draft.audioChunks
            sourceURL = chunks.first.flatMap { sources[$0.sourceID]?.url }
            hasAudio = sources.values.contains { $0.audioTrack != nil }
            videoCrop = draft.crop
            muteAudio = draft.muted
            rebuild(seekTo: 0)
            for source in sources.values { generateThumbnails(for: source) }
        } catch {
            statusMessage = "Couldn't restore the saved draft: \(error.localizedDescription)"
        }
    }

    /// Copy picked files into the app before picker/provider access expires.
    func importMobileFiles(_ urls: [URL], asAudio: Bool = false, consumingStagedFiles: Bool = false) async {
        guard !isImporting, !isExporting else { return }
        isImporting = true
        defer { isImporting = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let folder = mobileDocuments.appendingPathComponent("Media")
                    .appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(url.lastPathComponent)
                let canMove = consumingStagedFiles && MovieImportStorage.owns(url)
                try await Task.detached(priority: .userInitiated) {
                    if canMove { try FileManager.default.moveItem(at: url, to: destination) }
                    else { try FileManager.default.copyItem(at: url, to: destination) }
                }.value
                if asAudio {
                    await loadImportedAudio(url: destination)
                } else if hasContent {
                    _ = await appendImport(url: destination)
                } else {
                    _ = await loadFresh(url: destination)
                }
            } catch {
                statusMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        saveMobileDraft()
    }

    func newMobileProject() {
        clearAll()
        let media = mobileDocuments.appendingPathComponent("Media")
        try? FileManager.default.removeItem(at: media)
        exportedURL = nil
        saveMobileDraft()
    }

    var mobilePreviewGeometry: MobilePreviewGeometry? { mobileGeometry() }

    func mobileGeometry(crop: VideoCrop? = nil, framing: ClipFraming? = nil) -> MobilePreviewGeometry? {
        guard !chunks.isEmpty else { return nil }
        let chunk = chunkAtPlayhead().map { chunks[$0.index] } ?? chunks.last!
        guard let source = sources[chunk.sourceID] else { return nil }
        let canvas = crop ?? resolvedVideoCrop
        return MobilePreviewGeometry(encodedSize: source.encodedSize, outputSize: canvas.outputSize,
            transform: VideoGeometry.transform(encodedSize: source.encodedSize, preferred: source.preferredTransform,
                                               crop: canvas, framing: framing ?? chunk.framing ?? ClipFraming(),
                                               outputSize: canvas.outputSize))
    }

    func prepareMobileFraming() -> Chunk? {
        guard let chunk = selectedMobileChunk ?? chunkAtPlayhead().map({ chunks[$0.index] }) ?? chunks.first else { return nil }
        beginTrimPreview(chunk.id)
        let start = timelineStart(for: chunk)
        if currentTime < start || currentTime >= start + chunk.outputDuration {
            seek(to: start + min(0.03, chunk.outputDuration / 2))
        }
        return chunk
    }

    func mobileFillFraming(_ framing: ClipFraming, chunkID: UUID) -> ClipFraming {
        guard let chunk = chunks.first(where: { $0.id == chunkID }), let source = sources[chunk.sourceID] else { return framing }
        let crop = resolvedVideoCrop
        let size = source.naturalSize
        let fit = min(crop.canvasWidth / size.width, crop.canvasHeight / size.height)
        let halfW = size.width * fit / 2
        let halfH = size.height * fit / 2
        let radians = -framing.rotation * .pi / 180
        let corners = [CGPoint(x: -crop.rect.width / 2, y: -crop.rect.height / 2),
                       CGPoint(x: crop.rect.width / 2, y: -crop.rect.height / 2)]
        let required = corners.map { $0.applying(CGAffineTransform(rotationAngle: radians)) }
            .reduce(0.1) { max($0, abs($1.x) / halfW, abs($1.y) / halfH) }
        return ClipFraming(zoom: required, offsetX: (crop.rect.midX - crop.canvasWidth / 2) / crop.canvasWidth,
                           offsetY: (crop.rect.midY - crop.canvasHeight / 2) / crop.canvasHeight,
                           rotation: framing.rotation).clamped
    }

    var selectedMobileChunk: Chunk? {
        guard let id = selection.first else { return nil }
        return chunks.first { $0.id == id }
    }

    func moveMobileChunks(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ chunks.indices.contains($0) }),
              destination >= 0, destination <= chunks.count else { return }
        var reordered = chunks
        reordered.move(fromOffsets: offsets, toOffset: destination)
        guard reordered != chunks else { return }
        commit { chunks = reordered }
    }

    func sourceDuration(for chunk: Chunk) -> Double {
        sources[chunk.sourceID]?.duration ?? chunk.end
    }

    func timelineStart(for chunk: Chunk) -> Double {
        chunks.prefix { $0.id != chunk.id }.reduce(0) { $0 + $1.outputDuration }
    }

    func selectMobileChunk(_ chunk: Chunk) {
        beginTrimPreview(chunk.id)
        seek(to: timelineStart(for: chunk))
    }

    func exportMobile() {
        guard hasContent, !isExporting else { return }
        exportedURL = nil
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Reel Exports").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(defaultExportName())
            Task {
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
                await runExport(to: url, destination: .file,
                                resolution: exportResolution, compression: exportCompression)
            }
        } catch {
            statusMessage = "Couldn't prepare export: \(error.localizedDescription)"
        }
    }
}
#endif
