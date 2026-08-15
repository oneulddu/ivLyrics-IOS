import XCTest
@testable import ivLyrics_IOS

final class LyricsTimelineInterludeTests: XCTestCase {
    func testAutomaticBreakAppearsInsideLongGap() throws {
        let lines = [
            line(start: 1_000, end: 2_000, text: "first"),
            line(start: 10_000, end: 11_000, text: "second")
        ]
        let context = LyricsTimelineContext(lines: lines)

        let item = try XCTUnwrap(LyricsTimelineDisplayBuilder.previewItem(
            context: context,
            positionMs: 6_000,
            trackDurationMs: 12_000,
            autoInstrumentalBreakEnabled: true
        ))

        assertInterlude(item, start: 5_500, end: 10_000, kind: "break", automatic: true)

        let items = LyricsTimelineDisplayBuilder.items(
            context: context,
            positionMs: 6_000,
            trackDurationMs: 12_000,
            autoInstrumentalBreakEnabled: true
        )
        let activeInterlude = try XCTUnwrap(items.first { candidate in
            if case .interlude = candidate { return true }
            return false
        })
        assertInterlude(activeInterlude, start: 5_500, end: 10_000, kind: "break", automatic: true)
    }

    func testExplicitMarkerSuppressesAutomaticBreakBeforeIt() throws {
        let lines = [
            line(start: 1_000, end: 2_000, text: "first"),
            line(start: 7_000, end: 7_001, text: "♪"),
            line(start: 10_000, end: 11_000, text: "second")
        ]
        let context = LyricsTimelineContext(lines: lines)

        let beforeMarker = try XCTUnwrap(LyricsTimelineDisplayBuilder.previewItem(
            context: context,
            positionMs: 6_000,
            trackDurationMs: 12_000,
            autoInstrumentalBreakEnabled: true
        ))
        if case .line(let index, _, _) = beforeMarker {
            XCTAssertEqual(index, 0)
        } else {
            XCTFail("an automatic break must not overlap the upcoming explicit marker")
        }

        let marker = try XCTUnwrap(LyricsTimelineDisplayBuilder.previewItem(
            context: context,
            positionMs: 8_000,
            trackDurationMs: 12_000,
            autoInstrumentalBreakEnabled: true
        ))
        assertInterlude(marker, start: 7_000, end: 10_000, kind: "break", automatic: false)
    }

    func testPostludeUsesCurrentTrackDuration() throws {
        let lines = [line(start: 1_000, end: 2_000, text: "last")]
        let context = LyricsTimelineContext(lines: lines)

        let item = try XCTUnwrap(LyricsTimelineDisplayBuilder.previewItem(
            context: context,
            positionMs: 6_000,
            trackDurationMs: 12_000,
            autoInstrumentalBreakEnabled: true
        ))

        assertInterlude(item, start: 5_500, end: 12_000, kind: "postlude", automatic: true)
    }

    func testDisabledAutomaticBreakReturnsLyricLine() throws {
        let lines = [
            line(start: 1_000, end: 2_000, text: "first"),
            line(start: 10_000, end: 11_000, text: "second")
        ]
        let context = LyricsTimelineContext(lines: lines, cacheLyricEndTimes: false)

        let item = try XCTUnwrap(LyricsTimelineDisplayBuilder.previewItem(
            context: context,
            positionMs: 6_000,
            trackDurationMs: 12_000,
            autoInstrumentalBreakEnabled: false
        ))

        if case .line(let index, _, _) = item {
            XCTAssertEqual(index, 0)
        } else {
            XCTFail("automatic interlude must stay disabled")
        }
    }

    private func line(start: Int64, end: Int64, text: String) -> LyricsLine {
        LyricsLine(startTimeMs: start, endTimeMs: end, text: text)
    }

    private func assertInterlude(
        _ item: LyricsTimelineDisplayItem,
        start: Int64,
        end: Int64,
        kind: String,
        automatic: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .interlude(let info) = item else {
            XCTFail("expected interlude", file: file, line: line)
            return
        }
        XCTAssertEqual(info.startTimeMs, start, file: file, line: line)
        XCTAssertEqual(info.endTimeMs, end, file: file, line: line)
        XCTAssertEqual(info.kind, kind, file: file, line: line)
        XCTAssertEqual(info.automatic, automatic, file: file, line: line)
    }
}
