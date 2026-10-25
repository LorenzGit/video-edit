#if DEBUG
import AVFoundation
import CoreVideo

/// Deterministic media for simulator integration and interface checks.
enum MobileTestVideo {
    static func make(size: CGSize = CGSize(width: 360, height: 640), seconds: Int = 6,
                     withAudio: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Reel-sample-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width),
                                       height: Int(size.height), bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
                context.setFillColor(CGColor(red: 0.43, green: 0.55, blue: 1, alpha: 1))
                let y = CGFloat(frame % 150) / 150 * (size.height - 120)
                context.fillEllipse(in: CGRect(x: 60, y: y, width: 120, height: 120))
                context.setFillColor(CGColor(red: 0.2, green: 0.88, blue: 0.7, alpha: 1))
                context.fill(CGRect(x: size.width - 110, y: size.height * 0.3, width: 60, height: size.height * 0.4))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return withAudio ? try await addingTone(to: url, seconds: seconds) : url
    }

    private static func addingTone(to video: URL, seconds: Int) async throws -> URL {
        let tone = video.deletingPathExtension().appendingPathExtension("wav")
        let result = video.deletingPathExtension().appendingPathExtension("sound.mp4")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: tone) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48_000))!
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { samples[i] = Float(sin(Double(i) / 48_000 * 440 * .pi * 2)) * 0.2 }
        do {
            let audioFile = try AVAudioFile(forWriting: tone, settings: format.settings)
            try audioFile.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: Double(seconds), preferredTimescale: 600))
        for (url, kind) in [(video, AVMediaType.video), (tone, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: kind).first!
            try composition.addMutableTrack(withMediaType: kind, preferredTrackID: kCMPersistentTrackID_Invalid)!
                .insertTimeRange(range, of: track, at: .zero)
        }
        let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        session.outputURL = result
        session.outputFileType = .mp4
        await session.export()
        guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        return result
    }
}
#endif
