import XCTest
import AVFoundation
@testable import ReelMobile

@MainActor
final class EditorIntegrationTests: XCTestCase {
    private var root: URL!
    private var editor: EditorViewModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReelTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        editor = EditorViewModel()
        editor.mobileStorageRoot = root
    }

    override func tearDown() async throws {
        if let exported = editor.exportedURL {
            try? FileManager.default.removeItem(at: exported.deletingLastPathComponent())
        }
        editor.clearAll()
        editor = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testPhotosImportAdoptsStagedVideoAndRestoresAfterCleanup() async throws {
        let original = try await MobileTestVideo.make(seconds: 2)
        defer { try? FileManager.default.removeItem(at: original) }
        let staged = try await MovieImportStorage.stage(original)
        let before = try FileManager.default.attributesOfItem(atPath: staged.path)
        await editor.importMobileFiles([staged], consumingStagedFiles: true)
        let imported = try XCTUnwrap(editor.sourceURL)
        let after = try FileManager.default.attributesOfItem(atPath: imported.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber,
                       "Adopting Photos staging must rename the file, without copying its bytes again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        MovieImportStorage.discard(staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        let restored = EditorViewModel()
        restored.mobileStorageRoot = root
        await restored.restoreMobileDraft()
        XCTAssertTrue(restored.hasContent)
        XCTAssertEqual(restored.totalDuration, 2, accuracy: 0.04)
    }

    func testCancellingPhotosTransferRejectsLateVideoAndCleansStaging() async throws {
        let original = try await MobileTestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: original) }
        let staged = try await MovieImportStorage.stage(original)
        let loader = PhotoImportLoader()
        let transfer = Progress(totalUnitCount: 100)
        var callback: (@Sendable (Result<PickedMovie?, Error>) -> Void)?
        let loading = Task {
            try await loader.load { completion in
                callback = completion
                return transfer
            }
        }
        for _ in 0..<100 {
            if loader.isLoading { break }
            await Task.yield()
        }
        XCTAssertTrue(loader.isLoading)
        loader.cancel()
        do { _ = try await loading.value; XCTFail("Cancelled transfers must stop waiting immediately") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(transfer.isCancelled)
        XCTAssertFalse(loader.isLoading)
        callback?(.success(PickedMovie(url: staged)))
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: staged.path) { break }
            await Task.yield()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(editor.hasContent)
    }

    func testPreviewProducesFrames() async throws {
        let video = try await MobileTestVideo.make(seconds: 2)
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        let item = try XCTUnwrap(editor.player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        editor.togglePlay()
        defer { if editor.isPlaying { editor.togglePlay() } }
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if output.copyPixelBuffer(forItemTime: editor.player.currentTime(), itemTimeForDisplay: nil) != nil {
                XCTAssertEqual(item.status, .readyToPlay)
                return
            }
            if item.status == .failed { break }
        }
        XCTFail("Preview failed to decode: \(String(describing: item.error))")
    }

    func testSplitTrimSpeedReorderUndoAndDraftRecovery() async throws {
        let video = try await MobileTestVideo.make()
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        XCTAssertEqual(editor.chunks.count, 1)
        XCTAssertEqual(editor.totalDuration, 6, accuracy: 0.04)
        editor.seek(to: 2)
        editor.splitAtPlayhead()
        XCTAssertEqual(editor.chunks.count, 2)
        let first = editor.chunks[0]
        editor.select(first.id, additive: false)
        editor.setSpeed(2)
        XCTAssertEqual(editor.totalDuration, 5, accuracy: 0.04)
        let preview = editor.trimPreview(from: editor.chunks[0], edge: .leading, sourceDelta: 0.5)
        XCTAssertTrue(editor.commitTrimPreview(preview))
        XCTAssertEqual(editor.totalDuration, 4.75, accuracy: 0.04)
        editor.moveMobileChunks(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(editor.chunks[1].id, first.id)
        // A stationary drop must not consume an undo step.
        editor.moveMobileChunks(from: IndexSet(integer: 1), to: 2)
        editor.undo()
        XCTAssertEqual(editor.chunks[0].id, first.id)
        editor.redo()
        editor.muteAudio = true
        let restored = EditorViewModel()
        restored.mobileStorageRoot = root
        await restored.restoreMobileDraft()
        XCTAssertEqual(restored.chunks, editor.chunks)
        XCTAssertEqual(restored.totalDuration, editor.totalDuration, accuracy: 0.04)
        XCTAssertTrue(restored.muteAudio)
        XCTAssertNotNil(restored.player.currentItem)
        XCTAssertFalse(restored.canUndo)
        XCTAssertNil(restored.statusMessage)
    }

    func testExportMixedOrientationsAndRetiming() async throws {
        let portrait = try await MobileTestVideo.make()
        let landscape = try await MobileTestVideo.make(size: CGSize(width: 640, height: 360), seconds: 2)
        defer {
            try? FileManager.default.removeItem(at: portrait)
            try? FileManager.default.removeItem(at: landscape)
        }
        await editor.importMobileFiles([portrait, landscape])
        editor.setSpeed(2, all: true)
        editor.exportResolution = .scale50
        editor.exportCompression = .h264Balanced
        let url = try await export()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 180)
        XCTAssertEqual(size.height, 320)
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: CMTime(seconds: 3.5, preferredTimescale: 600)).image
        XCTAssertEqual(image.width, 180)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 1000)
    }

    func testAddedAudioSurvivesVideoMuteAndDraftRecovery() async throws {
        let video = try await MobileTestVideo.make(seconds: 2)
        let audio = root.appendingPathComponent("tone.wav")
        try makeAudio(at: audio)
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        await editor.importMobileFiles([audio], asAudio: true)
        XCTAssertTrue(editor.hasImportedAudioTrack)
        editor.selectMobileAudio(.added(editor.audioChunks[0].id))
        editor.setMobileAudioVolume(0.4)
        editor.seek(to: 1)
        editor.splitAtPlayhead()
        editor.setMobileAudioVolume(0)
        editor.setMobileAudioFade(true)
        XCTAssertEqual(editor.audioChunks.map(\.volume), [0.4, 0])
        editor.muteAudio = true
        let restored = EditorViewModel()
        restored.mobileStorageRoot = root
        await restored.restoreMobileDraft()
        XCTAssertEqual(restored.audioChunks, editor.audioChunks)
        XCTAssertTrue(restored.hasImportedAudioTrack)
        let url = try await export()
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let levels = try await audioRMS(url, windows: [0.2...0.8, 1.2...1.8])
        XCTAssertGreaterThan(levels[0], 0.02)
        XCTAssertLessThan(levels[1], 0.001)
    }

    func testDeletingLastClipCanUndoAndStartAgain() async throws {
        let video = try await MobileTestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        editor.select(editor.chunks[0].id, additive: false)
        editor.deleteSelected()
        XCTAssertFalse(editor.hasContent)
        editor.undo()
        XCTAssertTrue(editor.hasContent)
        editor.newMobileProject()
        let restored = EditorViewModel()
        restored.mobileStorageRoot = root
        await restored.restoreMobileDraft()
        XCTAssertFalse(restored.hasContent)
        XCTAssertFalse(restored.canUndo)
        await editor.importMobileFiles([video])
        XCTAssertTrue(editor.hasContent)
    }

    func testLocalAudioSectionsExportPersistAndFollowVideoEdits() async throws {
        let video = try await MobileTestVideo.make(withAudio: true)
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        XCTAssertTrue(editor.hasAudio)
        editor.seek(to: 2)
        editor.splitMobileAudioAtPlayhead()
        editor.setMobileAudioVolume(0.25)
        editor.seek(to: 4)
        editor.splitMobileAudioAtPlayhead()
        editor.setMobileAudioVolume(0)
        XCTAssertEqual(editor.chunks.count, 1, "Audio cuts must leave video continuous")
        XCTAssertEqual(editor.mobileVideoAudioSegments.map(\.volume), [1, 0.25, 0])
        editor.undo()
        XCTAssertEqual(editor.mobileVideoAudioSegments.map(\.volume), [1, 0.25, 0.25])
        editor.redo()
        let restored = EditorViewModel()
        restored.mobileStorageRoot = root
        await restored.restoreMobileDraft()
        XCTAssertEqual(restored.chunks, editor.chunks)
        editor.prepareMobileWaveforms()
        let sourceID = editor.chunks[0].sourceID
        for _ in 0..<100 {
            if editor.mobileWaveforms[sourceID] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(editor.mobileWaveforms[sourceID]?.max() ?? 0, 0.15)
        let firstExport = try await export()
        let levels = try await audioRMS(firstExport, windows: [0.5...1.5, 2.5...3.5, 4.5...5.5])
        XCTAssertGreaterThan(levels[0], 0.1)
        XCTAssertEqual(levels[1] / levels[0], 0.25, accuracy: 0.03)
        XCTAssertLessThan(levels[2], 0.001)
        try? FileManager.default.removeItem(at: firstExport.deletingLastPathComponent())
        editor.seek(to: 3)
        editor.splitAtPlayhead()
        editor.select(editor.chunks[0].id, additive: false)
        editor.setSpeed(2)
        editor.moveMobileChunks(from: IndexSet(integer: 0), to: 2)
        let edited = try await export()
        let shifted = try await audioRMS(edited, windows: [0.2...0.6, 1.3...2.5, 3.2...3.6])
        XCTAssertEqual(shifted[0] / shifted[2], 0.25, accuracy: 0.04)
        XCTAssertLessThan(shifted[1], 0.001)
        XCTAssertEqual(editor.totalDuration, 4.5, accuracy: 0.04)
        let trim = editor.trimPreview(from: editor.chunks[1], edge: .leading, sourceDelta: 0.5)
        _ = editor.commitTrimPreview(trim)
        XCTAssertEqual(editor.chunks[1].visibleAudioSections.map(\.volume), [1, 0.25])
        editor.restoreTrim(editor.chunks[1].id, edge: .leading)
        XCTAssertEqual(editor.chunks[1].visibleAudioSections.first?.start, 0)
        // Existing drafts have no audioSections key.
        let legacy = "{\"id\":\"\(UUID())\",\"sourceID\":\"\(UUID())\",\"start\":0,\"end\":6,\"speed\":1}"
        XCTAssertNil(try JSONDecoder().decode(Chunk.self, from: Data(legacy.utf8)).audioSections)
    }

    func testCropAndPerClipFramingMatchExportAndSurviveEdits() async throws {
        let video = try await MobileTestVideo.make()
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        editor.exportResolution = .source
        editor.seek(to: 3)
        editor.splitAtPlayhead()
        let firstID = editor.chunks[0].id
        let secondID = editor.chunks[1].id
        let crop = VideoCrop(canvasWidth: 360, canvasHeight: 640, x: 0.1, y: 0.2, width: 0.7, height: 0.5)
        editor.setVideoCrop(crop)
        let firstFrame = ClipFraming(zoom: 1.25, offsetX: 0.1, offsetY: -0.05, rotation: 90)
        let secondFrame = ClipFraming(zoom: 1.6, offsetX: -0.1, offsetY: 0.08, rotation: -25)
        editor.setClipFraming(firstFrame, for: firstID)
        editor.setClipFraming(secondFrame, for: secondID)
        editor.undo()
        XCTAssertNil(editor.chunks[1].framing)
        editor.redo()
        XCTAssertEqual(editor.chunks[1].framing, secondFrame)
        let exported = try await export()
        let outputAsset = AVURLAsset(url: exported)
        let outputTracks = try await outputAsset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(outputTracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 252, height: 320))
        let inputGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        let outputGenerator = AVAssetImageGenerator(asset: outputAsset)
        inputGenerator.requestedTimeToleranceBefore = .zero
        inputGenerator.requestedTimeToleranceAfter = .zero
        outputGenerator.requestedTimeToleranceBefore = .zero
        outputGenerator.requestedTimeToleranceAfter = .zero
        for (time, framing) in [(1.0, firstFrame), (4.0, secondFrame)] {
            editor.seek(to: time)
            let geometry = try XCTUnwrap(editor.mobilePreviewGeometry)
            let expected = VideoGeometry.transform(encodedSize: CGSize(width: 360, height: 640), preferred: .identity,
                                                   crop: crop, framing: framing, outputSize: size)
            let previewMatrix = [geometry.transform.a, geometry.transform.b, geometry.transform.c,
                                 geometry.transform.d, geometry.transform.tx, geometry.transform.ty]
            let exportMatrix = [expected.a, expected.b, expected.c, expected.d, expected.tx, expected.ty]
            for (preview, output) in zip(previewMatrix, exportMatrix) { XCTAssertEqual(preview, output, accuracy: 0.00000001) }
            let source = try await inputGenerator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let result = try await outputGenerator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            var error = 0.0
            var colored = 0
            for y in stride(from: 15, to: result.height - 10, by: 31) {
                for x in stride(from: 15, to: result.width - 10, by: 29) {
                    let position = CGPoint(x: Double(x), y: Double(y)).applying(expected.inverted())
                    let reference = sampleRGB(source, at: position)
                    let actual = sampleRGB(result, at: CGPoint(x: x, y: y))
                    error += zip(reference, actual).map { abs($0 - $1) }.reduce(0, +) / 3
                    if reference.max() ?? 0 > 0.4 { colored += 1 }
                }
            }
            XCTAssertGreaterThan(colored, 3, "Check colored landmarks, not only the flat background")
            XCTAssertLessThan(error / 80, 0.035, "Export pixels must match the framing matrix used by preview")
        }
        editor.moveMobileChunks(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(editor.chunks[1].framing, firstFrame)
        XCTAssertEqual(editor.videoCrop, crop)
        let trim = editor.trimPreview(from: editor.chunks[1], edge: .leading, sourceDelta: 0.5)
        _ = editor.commitTrimPreview(trim)
        XCTAssertEqual(editor.chunks[1].framing, firstFrame)
        editor.seek(to: 1)
        editor.splitAtPlayhead()
        XCTAssertEqual(editor.chunks[0].framing, secondFrame)
        XCTAssertEqual(editor.chunks[1].framing, secondFrame)
        let restored = EditorViewModel()
        restored.mobileStorageRoot = root
        await restored.restoreMobileDraft()
        XCTAssertEqual(restored.videoCrop, crop)
        XCTAssertEqual(restored.chunks, editor.chunks)
        editor.newMobileProject()
        XCTAssertNil(editor.videoCrop)
    }

    func testAudioFadeRampsNeighborsWithoutLeakingIntoMutedSpot() async throws {
        let video = try await MobileTestVideo.make(withAudio: true)
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        editor.seek(to: 2)
        editor.splitMobileAudioAtPlayhead()
        editor.seek(to: 4)
        editor.splitMobileAudioAtPlayhead()
        editor.selectMobileAudio(editor.mobileVideoAudioSegments[1].target)
        editor.setMobileAudioVolume(0)
        editor.setMobileAudioFade(true)
        XCTAssertTrue(editor.selectedMobileAudioSegment?.fades == true)
        editor.undo()
        XCTAssertFalse(editor.selectedMobileAudioSegment?.fades == true)
        editor.redo()
        let exported = try await export()
        let levels = try await audioRMS(exported, windows: [1.5...1.7, 1.81...1.85, 1.93...1.97,
                                                            2.01...3.99, 4.01...4.05, 4.15...4.19, 4.3...4.5])
        XCTAssertGreaterThan(levels[0], levels[1] * 1.1)
        XCTAssertGreaterThan(levels[1], levels[2] * 2)
        XCTAssertLessThan(levels[3], 0.001)
        XCTAssertLessThan(levels[4] * 2, levels[5])
        XCTAssertLessThan(levels[5], levels[6])
        let restored = EditorViewModel()
        restored.mobileStorageRoot = root
        await restored.restoreMobileDraft()
        XCTAssertTrue(restored.mobileVideoAudioSegments[1].fades)
        XCTAssertEqual(restored.chunks, editor.chunks)
    }

    func testAudioRampBoundariesSurviveSubframeCutsAndSlowPlayback() async throws {
        let video = try await MobileTestVideo.make(withAudio: true)
        defer { try? FileManager.default.removeItem(at: video) }
        await editor.importMobileFiles([video])
        for time in [1.13741, 2.35959, 3.35249, 4.81771] {
            editor.seek(to: time)
            editor.splitAtPlayhead()
        }
        for chunk in editor.chunks {
            editor.select(chunk.id, additive: false)
            editor.setSpeed(0.1)
        }
        XCTAssertEqual(editor.chunks.count, 5)
        editor.seek(to: 3.7211)
        editor.splitMobileAudioAtPlayhead()
        editor.setMobileAudioVolume(0.3)
        editor.setMobileAudioFade(true)
        let exported = try await export()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
    }

    func testFramingHandlesVideoWithPortraitOrientationMetadata() async throws {
        let original = try await MobileTestVideo.make(size: CGSize(width: 640, height: 360), seconds: 2)
        let rotated = root.appendingPathComponent("portrait-metadata.mp4")
        defer { try? FileManager.default.removeItem(at: original) }
        let input = AVURLAsset(url: original)
        let tracks = try await input.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let composition = AVMutableComposition()
        let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: track, at: .zero)
        let orientation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        video.preferredTransform = orientation
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.outputURL = rotated
        session.outputFileType = .mp4
        await session.export()
        XCTAssertEqual(session.status, .completed)
        await editor.importMobileFiles([rotated])
        XCTAssertEqual(editor.resolvedVideoCrop.canvasSize, CGSize(width: 360, height: 640))
        let crop = editor.resolvedVideoCrop.aspect(1)
        editor.setVideoCrop(crop)
        let framing = ClipFraming(zoom: 1.2, offsetX: 0.05, offsetY: -0.1, rotation: -12)
        editor.setClipFraming(framing, for: editor.chunks[0].id)
        editor.exportResolution = .source
        let exported = try await export()
        let source = try await AVAssetImageGenerator(asset: input).image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let result = try await AVAssetImageGenerator(asset: AVURLAsset(url: exported)).image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let expected = VideoGeometry.transform(encodedSize: CGSize(width: 640, height: 360), preferred: orientation,
                                               crop: crop, framing: framing, outputSize: CGSize(width: 360, height: 360))
        var errors: [Double] = []
        for y in stride(from: 17, to: 350, by: 37) {
            for x in stride(from: 17, to: 350, by: 37) {
                let point = CGPoint(x: x, y: y)
                let reference = sampleRGB(source, at: point.applying(expected.inverted()))
                let actual = sampleRGB(result, at: point)
                errors.append(zip(reference, actual).map { abs($0 - $1) }.reduce(0, +) / 3)
            }
        }
        XCTAssertLessThan(errors.reduce(0, +) / Double(errors.count), 0.035)
    }

    private func sampleRGB(_ image: CGImage, at point: CGPoint) -> [Double] {
        guard point.x >= 0, point.x < Double(image.width), point.y >= 0, point.y < Double(image.height),
              let crop = image.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)) else { return [0, 0, 0] }
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map { Double($0) / 255 }
    }

    private func audioRMS(_ url: URL, windows: [ClosedRange<Double>]) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var sums = [Double](repeating: 0, count: windows.count)
        var counts = [Int](repeating: 0, count: windows.count)
        while let sample = output.copyNextSampleBuffer() {
            let data = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let rate = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee.mSampleRate
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
            _ = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for (index, value) in values.enumerated() {
                let time = start + Double(index) / rate
                for (window, range) in windows.enumerated() where range.contains(time) {
                    sums[window] += Double(value * value)
                    counts[window] += 1
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertTrue(counts.allSatisfy { $0 > 0 })
        return zip(sums, counts).map { sqrt($0 / Double(max(1, $1))) }
    }

    private func export() async throws -> URL {
        editor.exportMobile()
        for _ in 0..<600 {
            if let url = editor.exportedURL { return url }
            try await Task.sleep(nanoseconds: 100_000_000)
            if !editor.isExporting && editor.statusMessage?.hasPrefix("Export failed") == true { break }
        }
        XCTFail(editor.statusMessage ?? "Export timed out")
        throw CocoaError(.fileWriteUnknown)
    }

    private func makeAudio(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<96_000 { samples[i] = Float(sin(Double(i) / 48_000 * 440 * .pi * 2)) * 0.15 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
