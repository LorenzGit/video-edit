import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class ScreenRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case displayUnavailable
        case cannotCreateOutputFolder
        case cannotConfigureWriter(String)
        case captureDidNotProduceFrames
        case writerFailed(String)
        case alreadyRunning
        case notRunning

        var errorDescription: String? {
            switch self {
            case .displayUnavailable:
                return "The selected display is no longer available."
            case .cannotCreateOutputFolder:
                return "Reel couldn't create its recording folder in Movies."
            case .cannotConfigureWriter(let detail):
                return "Reel couldn't prepare the recording: \(detail)"
            case .captureDidNotProduceFrames:
                return "The recording ended before any screen frames arrived."
            case .writerFailed(let detail):
                return "The recording couldn't be saved: \(detail)"
            case .alreadyRunning:
                return "A screen recording is already running."
            case .notRunning:
                return "There is no active screen recording."
            }
        }
    }

    var unexpectedStopHandler: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.gamojo.reel.screen-recorder.samples")
    private let stopStateLock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?

    // Accessed only on sampleQueue after capture begins.
    private var sessionStarted = false
    private var receivedVideoFrame = false
    private var firstSampleTime = CMTime.invalid
    private var sessionStartUptime: TimeInterval = 0
    private var isStopping = false

    func start(
        selection: ScreenCaptureSelection,
        includeSystemAudio: Bool
    ) async throws -> URL {
        guard stream == nil else { throw RecorderError.alreadyRunning }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw RecorderError.displayUnavailable
        }

        let currentProcess = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter: SCContentFilter
        if let currentProcess {
            filter = SCContentFilter(
                display: display,
                excludingApplications: [currentProcess],
                exceptingWindows: []
            )
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let filterScale = CGFloat(filter.pointPixelScale)
        let scale = filterScale > 0 ? filterScale : selection.pointPixelScale
        let outputWidth = Self.evenPixelCount(selection.sourceRect.width * scale)
        let outputHeight = Self.evenPixelCount(selection.sourceRect.height * scale)
        let url = try Self.makeOutputURL()

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let codec: AVVideoCodecType = max(outputWidth, outputHeight) > 4096 ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.recommendedBitRate(width: outputWidth, height: outputHeight),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecorderError.cannotConfigureWriter("The selected capture size isn't supported by the video encoder.")
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecorderError.cannotConfigureWriter("The video track couldn't be added.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includeSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw RecorderError.cannotConfigureWriter("The speaker-audio encoder isn't available.")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.cannotConfigureWriter("The speaker-audio track couldn't be added.")
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw RecorderError.cannotConfigureWriter(
                writer.error?.localizedDescription ?? "The media writer didn't start."
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = selection.sourceRect
        configuration.width = outputWidth
        configuration.height = outputHeight
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.showsCursor = true
        configuration.capturesAudio = includeSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.streamName = "Reel Screen Recording"

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if includeSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.outputURL = url
        sampleQueue.sync {
            sessionStarted = false
            receivedVideoFrame = false
            firstSampleTime = .invalid
            sessionStartUptime = 0
        }
        setStopping(false)
        self.stream = stream

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.startCapture { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            resetAfterFailedStart()
            throw error
        }

        return url
    }

    func stop() async throws -> URL {
        guard let stream, let writer, let outputURL else { throw RecorderError.notRunning }
        setStopping(true)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.stopCapture { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            cancel()
            throw error
        }

        let didStartSession = sampleQueue.sync { () -> Bool in
            guard sessionStarted, receivedVideoFrame else { return false }
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - sessionStartUptime)
            let endTime = firstSampleTime + CMTime(seconds: elapsed, preferredTimescale: 600)
            writer.endSession(atSourceTime: endTime)
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            return true
        }

        guard didStartSession else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            reset()
            throw RecorderError.captureDidNotProduceFrames
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        let status = writer.status
        let error = writer.error
        reset()

        guard status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw RecorderError.writerFailed(error?.localizedDescription ?? "The media writer stopped unexpectedly.")
        }
        return outputURL
    }

    func cancel() {
        let url = outputURL
        setStopping(true)
        stream?.stopCapture { _ in }
        sampleQueue.sync {
            writer?.cancelWriting()
            sessionStarted = false
            receivedVideoFrame = false
            firstSampleTime = .invalid
            sessionStartUptime = 0
        }
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func resetAfterFailedStart() {
        writer?.cancelWriting()
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
        reset()
    }

    private func reset() {
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        outputURL = nil
        sampleQueue.sync {
            sessionStarted = false
            receivedVideoFrame = false
            firstSampleTime = .invalid
            sessionStartUptime = 0
        }
    }

    private func setStopping(_ value: Bool) {
        stopStateLock.lock()
        isStopping = value
        stopStateLock.unlock()
    }

    private func shouldReportUnexpectedStop() -> Bool {
        stopStateLock.lock()
        let shouldReport = !isStopping
        stopStateLock.unlock()
        return shouldReport
    }

    private static func evenPixelCount(_ value: CGFloat) -> Int {
        max(2, (Int(value.rounded()) / 2) * 2)
    }

    private static func recommendedBitRate(width: Int, height: Int) -> Int {
        // Roughly 0.12 bits per pixel at 60 fps, with sensible bounds for
        // small selections and high-resolution Retina displays.
        let estimated = Int(Double(width * height) * 60 * 0.12)
        return min(max(estimated, 4_000_000), 80_000_000)
    }

    private static func makeOutputURL() throws -> URL {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw RecorderError.cannotCreateOutputFolder
        }
        let folder = movies.appendingPathComponent("Reel", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RecorderError.cannotCreateOutputFolder
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Reel Recording \(formatter.string(from: Date()))"
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("mov")
            suffix += 1
        }
        return candidate
    }
}

extension ScreenRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .screen, !Self.isCompleteScreenFrame(sampleBuffer) { return }
        guard let writer, writer.status == .writing else { return }

        if !sessionStarted {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard presentationTime.isValid else { return }
            writer.startSession(atSourceTime: presentationTime)
            firstSampleTime = presentationTime
            sessionStartUptime = ProcessInfo.processInfo.systemUptime
            sessionStarted = true
        }

        switch type {
        case .screen:
            if let videoInput, videoInput.isReadyForMoreMediaData {
                receivedVideoFrame = videoInput.append(sampleBuffer) || receivedVideoFrame
            }
        case .audio:
            if let audioInput, audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private static func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete || status == .started
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard shouldReportUnexpectedStop() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.unexpectedStopHandler?(error)
        }
    }
}
