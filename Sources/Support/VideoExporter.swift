import AVFoundation
import CoreVideo
import Foundation

/// Renders the edited composition through AVAssetReader/Writer so output
/// dimensions and compression bitrate can be selected independently.
enum VideoExporter {
    enum ExportError: LocalizedError {
        case noVideoTrack
        case unsupportedVideoSettings
        case unsupportedAudioSettings
        case cannotAddReaderOutput(String)
        case cannotAddWriterInput(String)
        case readerFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                "The edited video has no readable video track."
            case .unsupportedVideoSettings:
                "The selected video compression isn't supported on this Mac."
            case .unsupportedAudioSettings:
                "The selected audio compression isn't supported on this Mac."
            case .cannotAddReaderOutput(let media):
                "The \(media) track couldn't be prepared for export."
            case .cannotAddWriterInput(let media):
                "The \(media) encoder couldn't be added to the export."
            case .readerFailed(let detail):
                "The edited video couldn't be read: \(detail)"
            case .writerFailed(let detail):
                "The MP4 couldn't be encoded: \(detail)"
            }
        }
    }

    static func export(
        asset: AVAsset,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix?,
        outputURL: URL,
        codec: AVVideoCodecType,
        averageVideoBitRate: Int,
        averageAudioBitRate: Int,
        frameRate: Double,
        progress: @escaping (Double) -> Void
    ) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.cannotAddReaderOutput("video")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.audioMix = audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw ExportError.cannotAddReaderOutput("audio")
            }
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let size = videoComposition.renderSize
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageVideoBitRate,
                AVVideoExpectedSourceFrameRateKey: max(1, Int(frameRate.rounded())),
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw ExportError.unsupportedVideoSettings
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw ExportError.cannotAddWriterInput("video")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: averageAudioBitRate
            ]
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw ExportError.unsupportedAudioSettings
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ExportError.cannotAddWriterInput("audio")
            }
            writer.add(input)
            audioInput = input
        }

        let duration = try await asset.load(.duration).seconds
        let coordinator = ExportCoordinator(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput,
            duration: duration,
            progress: progress
        )
        try await coordinator.run()
    }
}

private final class ExportCoordinator {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderOutput?
    private let audioInput: AVAssetWriterInput?
    private let duration: Double
    private let progress: (Double) -> Void
    private let stateLock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var remainingInputs: Int
    private var isFinishing = false
    private var isResolved = false
    private var lastReportedProgress = 0.0

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderOutput?,
        audioInput: AVAssetWriterInput?,
        duration: Double,
        progress: @escaping (Double) -> Void
    ) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.duration = max(duration, 0.001)
        self.progress = progress
        remainingInputs = audioOutput == nil ? 1 : 2
    }

    func run() async throws {
        guard writer.startWriting() else {
            throw VideoExporter.ExportError.writerFailed(
                writer.error?.localizedDescription ?? "The encoder didn't start."
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw VideoExporter.ExportError.readerFailed(
                reader.error?.localizedDescription ?? "The reader didn't start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            self.continuation = continuation
            stateLock.unlock()

            pump(
                output: videoOutput,
                input: videoInput,
                queue: DispatchQueue(label: "com.gamojo.reel.export.video"),
                reportsProgress: true
            )
            if let audioOutput, let audioInput {
                pump(
                    output: audioOutput,
                    input: audioInput,
                    queue: DispatchQueue(label: "com.gamojo.reel.export.audio"),
                    reportsProgress: false
                )
            }
        }
    }

    private func pump(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        queue: DispatchQueue,
        reportsProgress: Bool
    ) {
        var didFinish = false
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, !didFinish else { return }

            while input.isReadyForMoreMediaData, !didFinish {
                if reader.status == .failed {
                    didFinish = true
                    input.markAsFinished()
                    fail(
                        VideoExporter.ExportError.readerFailed(
                            reader.error?.localizedDescription ?? "Unknown reader error."
                        )
                    )
                    return
                }
                if writer.status == .failed {
                    didFinish = true
                    input.markAsFinished()
                    fail(
                        VideoExporter.ExportError.writerFailed(
                            writer.error?.localizedDescription ?? "Unknown encoder error."
                        )
                    )
                    return
                }

                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    didFinish = true
                    input.markAsFinished()
                    inputDidFinish()
                    return
                }

                guard input.append(sampleBuffer) else {
                    didFinish = true
                    input.markAsFinished()
                    fail(
                        VideoExporter.ExportError.writerFailed(
                            writer.error?.localizedDescription ?? "The encoder rejected a media sample."
                        )
                    )
                    return
                }

                if reportsProgress {
                    reportProgress(for: sampleBuffer)
                }
            }
        }
    }

    private func reportProgress(for sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let value = max(0, min(timestamp / duration, 0.99))
        guard value - lastReportedProgress >= 0.005 else { return }
        lastReportedProgress = value
        progress(value)
    }

    private func inputDidFinish() {
        var shouldFinish = false
        stateLock.lock()
        if !isResolved {
            remainingInputs -= 1
            if remainingInputs == 0, !isFinishing {
                isFinishing = true
                shouldFinish = true
            }
        }
        stateLock.unlock()

        guard shouldFinish else { return }
        if reader.status == .failed {
            fail(
                VideoExporter.ExportError.readerFailed(
                    reader.error?.localizedDescription ?? "Unknown reader error."
                )
            )
            return
        }

        writer.finishWriting { [weak self] in
            guard let self else { return }
            if writer.status == .completed {
                resolve(.success(()))
            } else {
                resolve(
                    .failure(
                        VideoExporter.ExportError.writerFailed(
                            writer.error?.localizedDescription ?? "The encoder stopped unexpectedly."
                        )
                    )
                )
            }
        }
    }

    private func fail(_ error: Error) {
        reader.cancelReading()
        writer.cancelWriting()
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Void, Error>) {
        var pendingContinuation: CheckedContinuation<Void, Error>?
        stateLock.lock()
        if !isResolved {
            isResolved = true
            pendingContinuation = continuation
            continuation = nil
        }
        stateLock.unlock()

        guard let pendingContinuation else { return }
        switch result {
        case .success:
            pendingContinuation.resume()
        case .failure(let error):
            pendingContinuation.resume(throwing: error)
        }
    }
}
