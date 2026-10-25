import XCTest
import UIKit

final class MobileEditorUITests: XCTestCase {
    @MainActor
    func testEditAndExportOnPhone() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reel-ui-testing"]
        app.launch()
        let clip = app.buttons["clip-0"]
        XCTAssertTrue(clip.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Play"].tap()
        let advancing = NSPredicate { _, _ in
            let label = app.staticTexts["playheadTime"].label
            return !label.isEmpty && label != "00:00.00"
        }
        expectation(for: advancing, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.buttons["Pause"].tap()
        attach("Portrait editor")
        let timeline = app.scrollViews["timelineScrollView"]
        XCTAssertTrue(timeline.exists)
        let beforeScrub = seconds(app.staticTexts["playheadTime"].label)
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -90, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.2)
        let afterScrub = seconds(app.staticTexts["playheadTime"].label)
        XCTAssertEqual(afterScrub - beforeScrub, 90 / 44, accuracy: 0.3,
                       "The filmstrip must map drag distance to edited time")
        app.buttons["clip-0"].tap()
        XCTAssertEqual(seconds(app.staticTexts["playheadTime"].label), afterScrub, accuracy: 0.05,
                       "Selecting a clip must preserve the playhead")
        app.buttons["Fit timeline"].tap()
        XCTAssertEqual(seconds(app.staticTexts["playheadTime"].label), afterScrub, accuracy: 0.05,
                       "Zooming must preserve the playhead")
        timeline.pinch(withScale: 1.25, velocity: 1)
        XCTAssertEqual(seconds(app.staticTexts["playheadTime"].label), afterScrub, accuracy: 0.05,
                       "Pinch zoom must keep the current frame beneath the fixed playhead")
        app.buttons["Split"].tap()
        XCTAssertTrue(app.buttons["clip-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["More editing tools"].exists)
        XCTAssertFalse(app.buttons["Arrange clips"].exists)
        app.buttons["clip-0"].tap()
        app.buttons["Speed"].tap()
        app.buttons["2×"].tap()
        XCTAssertFalse(app.buttons["Trim"].exists)
        app.buttons["Undo"].tap()
        app.buttons["Redo"].tap()
        attach("Edited timeline")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLayout(app, landscape: true)
        attach("Landscape editor")
        XCUIDevice.shared.orientation = .portrait
        waitForLayout(app, landscape: false)
        app.buttons["Export video"].tap()
        XCTAssertTrue(app.buttons["exportAndShare"].waitForExistence(timeout: 5))
        attach("Export settings")
        app.buttons["exportAndShare"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 30)
                      || app.buttons["Copy"].waitForExistence(timeout: 10))
        attach("Share exported MP4")
    }

    @MainActor
    func testImportOriginalVideoFromPhotos() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reel-photo-testing"]
        app.launch()
        let choose = app.buttons["Choose videos"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        attach("Photos picker")
        let cell = app.cells.firstMatch
        guard cell.waitForExistence(timeout: 10) else {
            if app.navigationBars["PUPickerUnavailableView"].exists {
                throw XCTSkip("The simulator Photos picker service is unavailable.")
            }
            throw XCTSkip("Seed a video in the simulator Photos library to run the Photos import smoke test.")
        }
        cell.tap()
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        let start = Date()
        add.tap()
        XCTAssertTrue(app.buttons["clip-0"].waitForExistence(timeout: 15), app.debugDescription)
        print("PHOTOS_IMPORT_SECONDS=\(Date().timeIntervalSince(start))")
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Pause"].tap()
        attach("Photos import")
    }

    @MainActor
    func testDirectTrimHandlesCreateOneUndoStep() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reel-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["clip-0"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Fit timeline"].tap()
        // Scroll near the end so the right trim handle is visible.
        let timeline = app.scrollViews["timelineScrollView"]
        let origin = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.08))
        origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: -150, dy: 0)),
                     withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.2)
        app.buttons["clip-0"].tap()
        let handle = app.descendants(matching: .any).matching(identifier: "trimHandleEnd").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let before = seconds(app.staticTexts["totalDuration"].label)
        let point = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: -40, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.2)
        XCTAssertLessThan(seconds(app.staticTexts["totalDuration"].label), before - 0.3)
        attach("Direct clip trimming")
        app.buttons["Undo"].tap()
        XCTAssertEqual(seconds(app.staticTexts["totalDuration"].label), before, accuracy: 0.05)
        app.buttons["Redo"].tap()
        XCTAssertLessThan(seconds(app.staticTexts["totalDuration"].label), before - 0.3)
    }

    @MainActor
    func testFitFillsTheAvailableWidthAndKeepsBothEndsVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reel-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["clip-0"].waitForExistence(timeout: 15))
        let before = seconds(app.staticTexts["playheadTime"].label)
        app.buttons["Fit timeline"].tap()
        XCTAssertEqual(seconds(app.staticTexts["playheadTime"].label), before, accuracy: 0.05)
        assertFullFit(app)
        attach("Full-width fit")
        let timeline = app.scrollViews["timelineScrollView"]
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55))
        let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 120), thenHoldForDuration: 0.2)
        XCTAssertGreaterThan(seconds(app.staticTexts["playheadTime"].label), 4.5)
        assertFullFit(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLayout(app, landscape: true)
        assertFullFit(app)
        attach("Full-width fit in landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForLayout(app, landscape: false)
        assertFullFit(app)
    }

    @MainActor
    func testHoldAndDragReordersClipsAndUndoRestoresTheWholeMove() throws {
        let app = launchThreeClips()
        // Different edited durations exercise unequal drop slots.
        app.buttons["clip-1"].tap()
        app.buttons["Speed"].tap()
        app.buttons["2×"].tap()
        let original = clipSources(app)
        let duration = seconds(app.staticTexts["totalDuration"].label)
        let currentTime = seconds(app.staticTexts["playheadTime"].label)
        let first = app.buttons["clip-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let last = app.buttons["clip-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
        first.press(forDuration: 0.5, thenDragTo: last,
                    withVelocity: XCUIGestureVelocity(rawValue: 120), thenHoldForDuration: 0.2)
        XCTAssertEqual(clipSources(app), [original[1], original[2], original[0]])
        XCTAssertEqual(seconds(app.staticTexts["totalDuration"].label), duration, accuracy: 0.05)
        XCTAssertEqual(seconds(app.staticTexts["playheadTime"].label), currentTime, accuracy: 0.05)
        attach("Clip dragged to end")
        app.buttons["Undo"].tap()
        XCTAssertEqual(clipSources(app), original, "A drop must be exactly one undo step")
        app.buttons["Redo"].tap()
        XCTAssertEqual(clipSources(app), [original[1], original[2], original[0]])
        let moved = app.buttons["clip-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let beginning = app.buttons["clip-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
        moved.press(forDuration: 0.5, thenDragTo: beginning,
                    withVelocity: XCUIGestureVelocity(rawValue: 120), thenHoldForDuration: 0.2)
        XCTAssertEqual(clipSources(app), original)
        // Lifting and putting a clip back must not add an undo entry.
        app.buttons["clip-0"].press(forDuration: 0.6)
        app.buttons["Undo"].tap()
        XCTAssertEqual(clipSources(app), [original[1], original[2], original[0]])
        app.buttons["Redo"].tap()
        XCTAssertEqual(clipSources(app), original)
    }

    @MainActor
    func testHeldClipScrollsAtTheTimelineEdge() throws {
        let app = launchThreeClips()
        let original = clipSources(app)
        let timeline = app.scrollViews["timelineScrollView"]
        let ruler = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.08))
        ruler.press(forDuration: 0.1, thenDragTo: ruler.withOffset(CGVector(dx: -15, dy: 0)),
                    withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.1)
        for _ in 0..<3 { app.buttons["Zoom in"].tap() }
        let before = seconds(app.staticTexts["playheadTime"].label)
        let first = app.buttons["clip-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let edge = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: 0.55))
        first.press(forDuration: 0.5, thenDragTo: edge,
                    withVelocity: XCUIGestureVelocity(rawValue: 160), thenHoldForDuration: 4)
        XCTAssertEqual(seconds(app.staticTexts["playheadTime"].label), before, accuracy: 0.05,
                       "Reorder autoscroll must not scrub the preview")
        app.buttons["Fit timeline"].tap()
        XCTAssertEqual(clipSources(app), [original[1], original[2], original[0]])
        attach("Reorder after edge autoscroll")
        app.buttons["Undo"].tap()
        XCTAssertEqual(clipSources(app), original)
    }

    @MainActor
    func testAudioLaneCanIsolateLowerAndMuteSoundWithoutCuttingVideo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reel-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["clip-0"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Trim"].exists)
        app.buttons["Fit timeline"].tap()
        app.buttons["Show audio timeline"].tap()
        XCTAssertTrue(app.buttons["audio-section-0"].waitForExistence(timeout: 5))
        let timeline = app.scrollViews["timelineScrollView"]
        for fraction in [0.34, 0.67] {
            let point = timeline.coordinate(withNormalizedOffset: CGVector(dx: fraction - 0.05, dy: 0.04))
            let target = timeline.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.04))
            point.press(forDuration: 0.1, thenDragTo: target,
                        withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.1)
            app.buttons["Split audio"].tap()
        }
        XCTAssertTrue(app.buttons["audio-section-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["clip-1"].exists, "Splitting audio must not cut video")
        app.buttons["audio-section-1"].tap()
        app.sliders["Audio section volume"].adjust(toNormalizedSliderPosition: 0.3)
        let volume = app.buttons["audio-section-1"].value as? String
        XCTAssertNotEqual(volume, "100 percent")
        XCTAssertNotEqual(volume, "0 percent")
        app.buttons["Mute audio section"].tap()
        XCTAssertEqual(app.buttons["audio-section-1"].value as? String, "0 percent")
        XCTAssertEqual(app.buttons["audio-section-0"].value as? String, "100 percent")
        XCTAssertEqual(app.buttons["audio-section-2"].value as? String, "100 percent")
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.buttons["audio-section-1"].value as? String, volume)
        app.buttons["Redo"].tap()
        app.buttons["Fade audio section"].tap()
        XCTAssertEqual(app.buttons["Fade audio section"].value as? String, "On")
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.buttons["Fade audio section"].value as? String, "Off")
        app.buttons["Redo"].tap()
        XCTAssertEqual(app.buttons["Fade audio section"].value as? String, "On")
        attach("Audio section muted")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLayout(app, landscape: true)
        XCTAssertTrue(app.buttons["Split audio"].isHittable)
        XCTAssertTrue(app.sliders["Audio section volume"].isHittable)
        let visibleVideo = NSPredicate { _, _ in
            guard let image = app.otherElements["Video preview"].screenshot().image.cgImage else { return false }
            var pixel = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 20
        }
        wait(for: [XCTNSPredicateExpectation(predicate: visibleVideo, object: nil)], timeout: 8)
        attach("Audio editor in landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForLayout(app, landscape: false)
        app.buttons["Hide audio timeline"].tap()
        XCTAssertFalse(app.buttons["audio-section-0"].exists)
        XCTAssertTrue(app.buttons["clip-0"].exists)
    }

    @MainActor
    func testCropAndClipFramingApplyCancelAndStayIndependent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-reel-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["clip-0"].waitForExistence(timeout: 15))
        app.buttons["Crop entire video"].tap()
        XCTAssertTrue(app.staticTexts["Crop video"].waitForExistence(timeout: 5))
        let original = app.staticTexts["cropDimensions"].label
        let corner = app.descendants(matching: .any).matching(identifier: "cropCorner-2").firstMatch
        XCTAssertTrue(corner.waitForExistence(timeout: 5), app.debugDescription)
        let point = corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(forDuration: 0.1, thenDragTo: point.withOffset(CGVector(dx: -40, dy: -65)),
                    withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.1)
        XCTAssertNotEqual(app.staticTexts["cropDimensions"].label, original)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "Cancel must not edit the project")
        app.buttons["Crop entire video"].tap()
        app.buttons["Crop 1:1"].tap()
        XCTAssertEqual(app.staticTexts["cropDimensions"].label, "360 × 360")
        let crop = app.descendants(matching: .any).matching(identifier: "cropMoveFrame").firstMatch
        let center = crop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 30)),
                     withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.1)
        attach("Project crop")
        app.buttons["Apply"].tap()
        let dismissedCrop = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["Crop video"])
        wait(for: [dismissedCrop], timeout: 5)
        app.buttons["Export video"].tap()
        XCTAssertTrue(app.navigationBars["Export video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Dimensions, 360 × 360"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Cancel"].tap()
        app.buttons["Fit timeline"].tap()
        let timeline = app.scrollViews["timelineScrollView"]
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.08))
        let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.08))
        start.press(forDuration: 0.1, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.1)
        app.buttons["Split"].tap()
        app.buttons["clip-0"].tap()
        app.buttons["Frame clip"].tap()
        XCTAssertTrue(app.sliders["Clip zoom"].waitForExistence(timeout: 5))
        let surface = app.otherElements["clipFramingGestures"]
        let before = surface.value as? String
        let touch = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        touch.press(forDuration: 0.1, thenDragTo: touch.withOffset(CGVector(dx: 30, dy: -15)),
                    withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.1)
        XCTAssertNotEqual(surface.value as? String, before)
        surface.pinch(withScale: 1.4, velocity: 1)
        surface.rotate(.pi / 6, withVelocity: 1)
        XCTAssertNotEqual(app.staticTexts["frameRotationValue"].label, "0°")
        app.buttons["Rotate clip 90 degrees"].tap()
        let rotation = app.staticTexts["frameRotationValue"].label
        let zoomBeforeSlider = app.staticTexts["frameZoomValue"].label
        let zoomSlider = app.sliders["Clip zoom"]
        let zoomStart = zoomSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.11, dy: 0.5))
        let zoomEnd = zoomSlider.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5))
        zoomStart.press(forDuration: 0.1, thenDragTo: zoomEnd,
                        withVelocity: XCUIGestureVelocity(rawValue: 60), thenHoldForDuration: 0.1)
        let zoom = app.staticTexts["frameZoomValue"].label
        XCTAssertNotEqual(zoom, zoomBeforeSlider, "Dragging the zoom slider must update the clip")
        XCTAssertNotEqual(zoom, "100%")
        attach("Individual clip framing")
        app.buttons["Apply"].tap()
        app.buttons["Frame clip"].tap()
        XCTAssertEqual(app.staticTexts["frameZoomValue"].label, zoom)
        XCTAssertEqual(app.staticTexts["frameRotationValue"].label, rotation)
        app.buttons["Reset clip framing"].tap()
        app.buttons["Cancel"].tap()
        app.buttons["Frame clip"].tap()
        XCTAssertEqual(app.staticTexts["frameZoomValue"].label, zoom)
        app.buttons["Cancel"].tap()
        app.buttons["clip-1"].tap()
        app.buttons["Frame clip"].tap()
        XCTAssertEqual(app.staticTexts["frameZoomValue"].label, "100%")
        XCTAssertEqual(app.staticTexts["frameRotationValue"].label, "0°")
        app.buttons["Cancel"].tap()
        app.buttons["Undo"].tap()
        app.buttons["clip-0"].tap()
        app.buttons["Frame clip"].tap()
        XCTAssertEqual(app.staticTexts["frameZoomValue"].label, "100%")
        app.buttons["Cancel"].tap()
    }

    @MainActor
    private func launchThreeClips() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-reel-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["clip-0"].waitForExistence(timeout: 15))
        app.buttons["Fit timeline"].tap()
        let timeline = app.scrollViews["timelineScrollView"]
        for fraction in [0.34, 0.67] {
            let point = timeline.coordinate(withNormalizedOffset: CGVector(dx: fraction - 0.05, dy: 0.08))
            let target = timeline.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.08))
            point.press(forDuration: 0.1, thenDragTo: target,
                        withVelocity: XCUIGestureVelocity(rawValue: 90), thenHoldForDuration: 0.1)
            app.buttons["Split"].tap()
        }
        XCTAssertTrue(app.buttons["clip-2"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(Set(clipSources(app)).count, 3)
        return app
    }

    @MainActor
    private func clipSources(_ app: XCUIApplication) -> [String] {
        (0..<3).map { app.buttons["clip-\($0)"].value as? String ?? "missing" }
    }

    @MainActor
    private func assertFullFit(_ app: XCUIApplication) {
        let timeline = app.scrollViews["timelineScrollView"].frame
        let clip = app.buttons["clip-0"].frame
        XCTAssertEqual(clip.minX, timeline.minX + 16, accuracy: 2)
        XCTAssertEqual(clip.maxX, timeline.maxX - 16, accuracy: 2)
        XCTAssertEqual(clip.width, timeline.width - 32, accuracy: 2)
    }

    @MainActor
    private func waitForLayout(_ app: XCUIApplication, landscape: Bool) {
        let settled = NSPredicate { _, _ in
            let window = app.windows.firstMatch.frame
            let preview = app.otherElements["Video preview"].frame
            let timeline = app.scrollViews["timelineScrollView"].frame
            if landscape {
                return window.width > window.height && preview.maxX < timeline.minX
            }
            return window.height > window.width && preview.maxY < timeline.minY
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        wait(for: [expectation], timeout: 8)
    }

    private func seconds(_ timecode: String) -> Double {
        timecode.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    @MainActor
    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
