import AVFoundation

/// Decode original samples off the main thread. Waveforms are cached separately
/// from editing state, so opening the audio lane never delays importing video.
enum AudioWaveform {
    static func read(url: URL, duration: Double, bins: Int = 2048) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard duration.isFinite, duration > 0, bins > 0,
              let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        defer { reader.cancelReading() }
        var peaks = [Float](repeating: 0, count: bins)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let data = CMSampleBufferGetDataBuffer(sample),
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { continue }
            let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let rate = description.pointee.mSampleRate
            guard start.isFinite, rate.isFinite, rate > 0 else { continue }
            for (index, value) in values.enumerated() {
                let bin = min(bins - 1, max(0, Int((start + Double(index) / rate) / duration * Double(bins))))
                if value.isFinite { peaks[bin] = max(peaks[bin], min(1, abs(value))) }
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return peaks
    }
}

enum MobileAudioTarget: Equatable {
    case video(chunkID: UUID, sectionID: UUID)
    case added(UUID)
}

struct MobileAudioSegment: Identifiable {
    let target: MobileAudioTarget
    let sourceID: UUID
    let start: Double
    let end: Double
    let timelineStart: Double
    let duration: Double
    let sourceDuration: Double
    let volume: Float
    let hasAudio: Bool
    let fades: Bool
    var id: String {
        switch target {
        case .video(let chunk, let section): return "\(chunk)-\(section)"
        case .added(let id): return id.uuidString
        }
    }
}
