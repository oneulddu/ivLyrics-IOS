import XCTest
@testable import ivLyrics_IOS

final class PictureInPictureRenderCadenceTests: XCTestCase {
    func testSyntheticLineKaraokeUsesAnimatedCadence() {
        let line = LyricsLine(startTimeMs: 1_000, endTimeMs: 8_000, text: "synthetic karaoke")

        XCTAssertEqual(
            PictureInPictureRenderCadence.framesPerSecond(
                line: line,
                syncedAnimationEnabled: true,
                displayGranularity: AppSettings.karaokeDisplayCharacter
            ),
            30
        )
        XCTAssertEqual(
            PictureInPictureRenderCadence.framesPerSecond(
                line: line,
                syncedAnimationEnabled: false,
                displayGranularity: AppSettings.karaokeDisplayCharacter
            ),
            12
        )
    }

    func testSyntheticVocalPartKaraokeUsesAnimatedCadence() {
        let part = LyricsLine.VocalPart(
            id: "synthetic-part",
            role: "lead",
            speaker: "vocal1",
            kind: "vocal",
            text: "synthetic vocal part",
            syllables: [
                .init(text: "synthetic ", startTimeMs: 1_000, endTimeMs: 1_000),
                .init(text: "vocal part", startTimeMs: 7_000, endTimeMs: 7_000)
            ]
        )
        let line = LyricsLine(
            startTimeMs: 1_000,
            endTimeMs: 7_000,
            text: "synthetic vocal part",
            vocalParts: [part]
        )

        XCTAssertEqual(
            PictureInPictureRenderCadence.framesPerSecond(
                line: line,
                syncedAnimationEnabled: true,
                displayGranularity: AppSettings.karaokeDisplayCharacter
            ),
            30
        )
    }

    func testActualTimingAndContinuousEffectsUseAnimatedCadence() {
        let timed = LyricsLine(
            startTimeMs: 1_000,
            endTimeMs: 8_000,
            text: "actual timing",
            syllables: [.init(text: "actual timing", startTimeMs: 1_000, endTimeMs: 8_000)]
        )
        XCTAssertEqual(
            PictureInPictureRenderCadence.framesPerSecond(
                line: timed,
                syncedAnimationEnabled: false,
                displayGranularity: AppSettings.karaokeDisplayCharacter
            ),
            30
        )

        let effect = LyricsLine(startTimeMs: 1_000, endTimeMs: 8_000, text: "wave", kind: "wave")
        XCTAssertEqual(
            PictureInPictureRenderCadence.framesPerSecond(
                line: effect,
                syncedAnimationEnabled: false,
                displayGranularity: AppSettings.karaokeDisplayLine
            ),
            30
        )
    }

    func testPlainLineGranularityStaysOnStaticCadence() {
        let line = LyricsLine(
            startTimeMs: 1_000,
            endTimeMs: 8_000,
            text: "plain line",
            syllables: [.init(text: "plain line", startTimeMs: 1_000, endTimeMs: 8_000)]
        )

        XCTAssertEqual(
            PictureInPictureRenderCadence.framesPerSecond(
                line: line,
                syncedAnimationEnabled: true,
                displayGranularity: AppSettings.karaokeDisplayLine
            ),
            12
        )
    }
}

@MainActor
final class PictureInPictureKaraokeLayoutTests: XCTestCase {
    func testArtworkLayoutsReserveHeaderSpaceForCurrentLyrics() {
        let controller = LyricsPictureInPictureController()
        for orientation in [AppSettings.pipOrientationSquare, AppSettings.pipOrientationPortrait] {
            _ = controller.debugFrameImage(
                orientation: orientation,
                showArtwork: true,
                backgroundMode: AppSettings.pipBackgroundGradient,
                vocalPartCount: 4
            )

            XCTAssertGreaterThan(controller.debugLastLyricsRect.minY, 120, orientation)
            assertPrimaryContentIsContained(controller, context: "reserved-header-\(orientation)")
        }
    }

    func testWrappedTranslationIsMeasuredAndKeptInsideViewport() {
        let controller = LyricsPictureInPictureController()
        _ = controller.debugFrameImage(
            orientation: AppSettings.pipOrientationLandscape,
            showArtwork: true,
            backgroundMode: AppSettings.pipBackgroundGradient,
            vocalPartCount: 1,
            translationText: ""
        )
        let lyricsOnlyHeight = controller.debugLastPrimaryImageSize.height

        _ = controller.debugFrameImage(
            orientation: AppSettings.pipOrientationLandscape,
            showArtwork: true,
            backgroundMode: AppSettings.pipBackgroundGradient,
            vocalPartCount: 1,
            translationText: "This translation is deliberately long enough to wrap across multiple visible lines without truncation."
        )

        XCTAssertGreaterThan(controller.debugLastPrimaryImageSize.height, lyricsOnlyHeight)
        assertPrimaryContentIsContained(controller, context: "wrapped-translation")
    }

    func testThreeAndFourVocalRowsStayInsideLyricsViewport() {
        let orientations = [
            AppSettings.pipOrientationLandscape,
            AppSettings.pipOrientationSquare,
            AppSettings.pipOrientationPortrait
        ]

        for orientation in orientations {
            for showArtwork in [false, true] {
                let controller = LyricsPictureInPictureController()
                _ = controller.debugFrameImage(
                    orientation: orientation,
                    showArtwork: showArtwork,
                    backgroundMode: AppSettings.pipBackgroundGradient,
                    vocalPartCount: 3
                )
                let threeRowHeight = controller.debugLastPrimaryImageSize.height
                assertPrimaryContentIsContained(controller, context: "\(orientation)-artwork:\(showArtwork)-3")

                _ = controller.debugFrameImage(
                    orientation: orientation,
                    showArtwork: showArtwork,
                    backgroundMode: AppSettings.pipBackgroundGradient,
                    vocalPartCount: 4
                )
                let fourRowHeight = controller.debugLastPrimaryImageSize.height
                assertPrimaryContentIsContained(controller, context: "\(orientation)-artwork:\(showArtwork)-4")
                XCTAssertGreaterThan(fourRowHeight, threeRowHeight)
            }
        }
    }

    private func assertPrimaryContentIsContained(
        _ controller: LyricsPictureInPictureController,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = controller.debugLastLyricsRect.insetBy(dx: -0.5, dy: -0.5)
        let primary = controller.debugLastPrimaryDrawRect
        XCTAssertGreaterThan(controller.debugLastPrimaryImageSize.width, 0, context, file: file, line: line)
        XCTAssertGreaterThan(controller.debugLastPrimaryImageSize.height, 0, context, file: file, line: line)
        XCTAssertGreaterThan(primary.width, 0, context, file: file, line: line)
        XCTAssertGreaterThan(primary.height, 0, context, file: file, line: line)
        XCTAssertTrue(viewport.contains(primary), "primary content escaped viewport: \(context)", file: file, line: line)
    }
}
