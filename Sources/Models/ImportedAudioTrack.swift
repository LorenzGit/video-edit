import AVFoundation
import Foundation

/// An imported audio file shared by every clip cut from it.
struct ImportedAudioSource {
    let id: UUID
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: Double

    init(
        id: UUID = UUID(),
        url: URL,
        asset: AVURLAsset,
        track: AVAssetTrack,
        duration: Double
    ) {
        self.id = id
        self.url = url
        self.asset = asset
        self.track = track
        self.duration = duration
    }
}

/// One editable clip in the thin audio lane above the video timeline.
/// Source times are independent from its absolute placement on the video.
struct AudioChunk: Identifiable, Equatable {
    let id: UUID
    var sourceID: UUID
    var start: Double
    var end: Double
    var timelineStart: Double
    var speed: Double
    var volume: Float
    var fadeInDuration: Double
    var fadeOutDuration: Double

    init(
        id: UUID = UUID(),
        sourceID: UUID,
        start: Double,
        end: Double,
        timelineStart: Double = 0,
        speed: Double = 1,
        volume: Float = 1,
        fadeInDuration: Double = 0,
        fadeOutDuration: Double = 0
    ) {
        self.id = id
        self.sourceID = sourceID
        self.start = start
        self.end = end
        self.timelineStart = timelineStart
        self.speed = speed
        self.volume = volume
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
    }

    var sourceDuration: Double { max(0, end - start) }
    var outputDuration: Double { speed > 0 ? sourceDuration / speed : sourceDuration }
    var timelineEnd: Double { timelineStart + outputDuration }
}
