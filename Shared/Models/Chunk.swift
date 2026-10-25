import Foundation

/// Source-relative gain sections stay attached through video trims, moves and speed changes.
struct ClipAudioSection: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var volume: Float = 1
    var fades: Bool?
}

/// One segment of the timeline. A freshly-loaded video is a single chunk
/// spanning `0...duration` at `1×`. Splitting divides a chunk in two;
/// changing speed only affects how long it plays back. Chunks can come from
/// different imported videos, identified by `sourceID`.
///
/// `start`/`end` are measured in seconds of that source asset. `speed` is a
/// playback multiplier (2 = twice as fast, 0.5 = half speed).
struct Chunk: Identifiable, Equatable, Codable {
    let id: UUID
    var sourceID: UUID
    var start: Double
    var end: Double
    var speed: Double
    var audioSections: [ClipAudioSection]?
    var framing: ClipFraming?

    init(id: UUID = UUID(), sourceID: UUID, start: Double, end: Double, speed: Double = 1.0,
         audioSections: [ClipAudioSection]? = nil, framing: ClipFraming? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.start = start
        self.end = end
        self.speed = speed
        self.audioSections = audioSections
        self.framing = framing
    }

    var visibleAudioSections: [ClipAudioSection] {
        (audioSections ?? [ClipAudioSection(id: id, start: start, end: end)]).compactMap { section in
            let lower = max(start, section.start)
            let upper = min(end, section.end)
            guard upper > lower else { return nil }
            return ClipAudioSection(id: section.id, start: lower, end: upper, volume: section.volume, fades: section.fades)
        }
    }

    /// Length of the underlying source footage, in seconds.
    var sourceDuration: Double { max(0, end - start) }

    /// How long this chunk occupies on the edited timeline, after speed.
    var outputDuration: Double { speed > 0 ? sourceDuration / speed : sourceDuration }
}
