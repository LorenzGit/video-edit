import AVFoundation

/// Transitions stay in the louder section. A muted spot remains silent for
/// its entire duration while its neighbors fade down to it and back up.
enum AudioGainEnvelope {
    struct Span {
        var start: Double
        var duration: Double
        var volume: Float
        var fades: Bool
        var end: Double { start + duration }
    }
    struct Ramp {
        var start: Double
        var duration: Double
        var from: Float
        var to: Float
        func apply(to parameters: AVMutableAudioMixInputParameters) {
            guard start.isFinite, duration.isFinite, duration > 0.000001 else { return }
            // Round shared boundaries, not each duration independently. The
            // composition uses 600 ticks; mismatched clocks can overlap ramps.
            let lower = CMTime(seconds: max(0, start), preferredTimescale: 600)
            let upper = CMTime(seconds: max(0, start + duration), preferredTimescale: 600)
            guard upper > lower else { return }
            parameters.setVolumeRamp(fromStartVolume: from, toEndVolume: to,
                                     timeRange: CMTimeRange(start: lower, end: upper))
        }
    }
    static func ramps(at index: Int, in spans: [Span]) -> [Ramp] {
        let span = spans[index]
        let previous = index > 0 && abs(spans[index - 1].end - span.start) < 0.001 ? spans[index - 1] : nil
        let next = index + 1 < spans.count && abs(span.end - spans[index + 1].start) < 0.001 ? spans[index + 1] : nil
        let entry = previous?.volume ?? (span.fades ? 0 : span.volume)
        let exit = next?.volume ?? (span.fades ? 0 : span.volume)
        let fadeIn = (span.fades || previous?.fades == true) && entry < span.volume ? min(0.2, span.duration / 2) : 0
        let fadeOut = (span.fades || next?.fades == true) && exit < span.volume ? min(0.2, span.duration / 2) : 0
        var result: [Ramp] = []
        if fadeIn > 0 { result.append(Ramp(start: span.start, duration: fadeIn, from: entry, to: span.volume)) }
        result.append(Ramp(start: span.start + fadeIn, duration: span.duration - fadeIn - fadeOut,
                           from: span.volume, to: span.volume))
        if fadeOut > 0 { result.append(Ramp(start: span.end - fadeOut, duration: fadeOut, from: span.volume, to: exit)) }
        return result
    }
}
