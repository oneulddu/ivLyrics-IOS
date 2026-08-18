import XCTest
@testable import ivLyrics_IOS

final class UpstreamIntegrationRegressionTests: XCTestCase {
    func testTimedChunksCoalesceGraphemeBoundariesAndPreserveFullTimingSpan() {
        let thai = KaraokeSyllableTimingNormalizer.expandTimedChunks([
            .init(text: "น", startTimeMs: 0, endTimeMs: 100),
            .init(text: "้", startTimeMs: 100, endTimeMs: 200),
            .init(text: "ำ", startTimeMs: 200, endTimeMs: 300)
        ])
        XCTAssertEqual(thai.map(\.text), ["น้ำ"])
        XCTAssertEqual(thai.first?.startTimeMs, 0)
        XCTAssertEqual(thai.first?.endTimeMs, 300)

        let arabic = KaraokeSyllableTimingNormalizer.expandTimedChunks([
            .init(text: "ر", startTimeMs: 400, endTimeMs: 520),
            .init(text: "َ", startTimeMs: 520, endTimeMs: 580)
        ])
        XCTAssertEqual(arabic.map(\.text), ["رَ"])
        XCTAssertEqual(arabic.first?.startTimeMs, 400)
        XCTAssertEqual(arabic.first?.endTimeMs, 580)
    }

    func testLyricsResultSyncMetadataDefaultsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(LyricsResult.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.syncType, "unknown")
        XCTAssertEqual(legacy.syncPoints, 0)

        let result = LyricsResult(
            lines: [.init(startTimeMs: 0, endTimeMs: 1_000, text: "Signal")],
            providerLabel: "ivLyrics sync-data + LRCLIB",
            detail: "fixture",
            karaoke: true,
            contributors: [
                .init(name: "Creator", syncType: "WORD", syncPoints: 17)
            ],
            syncType: "CHARACTER",
            syncPoints: 42
        )

        XCTAssertEqual(result.syncType, "character")
        XCTAssertEqual(result.syncPoints, 42)
        XCTAssertEqual(result.contributors.first?.syncType, "word")
        XCTAssertEqual(result.contributors.first?.syncPoints, 17)

        let selected = result.withSelection(providerId: "LRCLIB", selectionPolicyKey: "policy-v1")
        XCTAssertEqual(selected.syncType, "character")
        XCTAssertEqual(selected.syncPoints, 42)

        let decoded = try JSONDecoder().decode(LyricsResult.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(decoded, selected)
    }

    func testPronunciationNotationNormalizesPersistsAndChangesSnapshotCacheKey() {
        let suiteName = "UpstreamIntegrationRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("IPA", forKey: "pronunciation_notation_v1")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.pronunciationNotation, AppSettings.pronunciationNotationIPA)
        let ipaCacheKey = settings.snapshot.cacheKey

        settings.pronunciationNotation = AppSettings.pronunciationNotationLatin
        XCTAssertEqual(defaults.string(forKey: "pronunciation_notation_v1"), AppSettings.pronunciationNotationLatin)
        XCTAssertNotEqual(settings.snapshot.cacheKey, ipaCacheKey)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.pronunciationNotation, AppSettings.pronunciationNotationLatin)
        XCTAssertEqual(AppSettings.normalizePronunciationNotation("unsupported"), AppSettings.pronunciationNotationTranslation)
    }

    func testDuplicatePronunciationComparisonIgnoresPresentationOnlyDifferences() {
        XCTAssertTrue(IvLyricsUtilities.lyricsTextsEquivalent("  Hello   world  ", "Hello world"))
        XCTAssertTrue(IvLyricsUtilities.lyricsTextsEquivalent("ＡＢＣ", "ABC"))
        XCTAssertFalse(IvLyricsUtilities.lyricsTextsEquivalent("hello", "안녕하세요"))
    }
}
