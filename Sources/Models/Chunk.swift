import Foundation

/// One segment of the timeline. A freshly-loaded video is a single chunk
/// spanning `0...duration` at `1×`. Splitting divides a chunk in two;
/// changing speed only affects how long it plays back. Chunks can come from
/// different imported videos, identified by `sourceID`.
///
/// `start`/`end` are measured in seconds of that source asset. `speed` is a
/// playback multiplier (2 = twice as fast, 0.5 = half speed).
struct Chunk: Identifiable, Equatable {
    let id: UUID
    var sourceID: UUID
    var start: Double
    var end: Double
    var speed: Double

    init(id: UUID = UUID(), sourceID: UUID, start: Double, end: Double, speed: Double = 1.0) {
        self.id = id
        self.sourceID = sourceID
        self.start = start
        self.end = end
        self.speed = speed
    }

    /// Length of the underlying source footage, in seconds.
    var sourceDuration: Double { max(0, end - start) }

    /// How long this chunk occupies on the edited timeline, after speed.
    var outputDuration: Double { speed > 0 ? sourceDuration / speed : sourceDuration }
}
