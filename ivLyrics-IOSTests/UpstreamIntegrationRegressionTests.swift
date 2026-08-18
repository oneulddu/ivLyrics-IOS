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

    func testWordDisplayPreservesExistingLatinAndArabicWordUnits() {
        let latin = KaraokeSyllableTimingNormalizer.groupedForWordDisplay([
            .init(text: "hello", startTimeMs: 0, endTimeMs: 500, sourceGranularity: "word"),
            .init(text: " ", startTimeMs: 500, endTimeMs: 600, sourceGranularity: "word"),
            .init(text: "world", startTimeMs: 600, endTimeMs: 1_100, sourceGranularity: "word")
        ], locale: "en")
        XCTAssertEqual(latin.map(\.text), ["hello", " ", "world"])
        XCTAssertEqual(latin.map(\.startTimeMs), [0, 500, 600])
        XCTAssertEqual(latin.map(\.endTimeMs), [500, 600, 1_100])

        let arabic = KaraokeSyllableTimingNormalizer.groupedForWordDisplay([
            .init(text: "سلام", startTimeMs: 0, endTimeMs: 700, sourceGranularity: "word"),
            .init(text: " ", startTimeMs: 700, endTimeMs: 760, sourceGranularity: "word"),
            .init(text: "عليكم", startTimeMs: 760, endTimeMs: 1_500, sourceGranularity: "word")
        ], locale: "ar")
        XCTAssertEqual(arabic.map(\.text), ["سلام", " ", "عليكم"])
        XCTAssertEqual(arabic.map(\.startTimeMs), [0, 700, 760])
        XCTAssertEqual(arabic.map(\.endTimeMs), [700, 760, 1_500])
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
        XCTAssertEqual(IvLyricsUtilities.distinctPronunciation("  Hello   world  ", original: "Hello world"), "")
        XCTAssertEqual(IvLyricsUtilities.distinctPronunciation("annyeong", original: "안녕"), "annyeong")
    }

    func testCachedFallbackPreservesSelectionAndSyncMetadata() {
        let cached = LyricsResult(
            lines: [.init(startTimeMs: 0, endTimeMs: 1_000, text: "Signal")],
            providerLabel: "LRCLIB synced",
            detail: "cached",
            karaoke: true,
            isrc: "USRC17607839",
            spotifyTrackId: "old-track",
            contributors: [.init(name: "Creator", syncType: "word", syncPoints: 9)],
            providerId: "lrclib",
            selectionPolicyKey: "policy-v1",
            syncType: "word",
            syncPoints: 27
        )

        let fallback = LyricsRepository.cachedFallbackResult(
            from: cached,
            detail: "fallback",
            isrc: "USRC17607839",
            spotifyTrackId: "new-track"
        )

        XCTAssertFalse(fallback.karaoke)
        XCTAssertEqual(fallback.detail, "fallback")
        XCTAssertEqual(fallback.spotifyTrackId, "new-track")
        XCTAssertEqual(fallback.providerId, "lrclib")
        XCTAssertEqual(fallback.selectionPolicyKey, "policy-v1")
        XCTAssertEqual(fallback.syncType, "word")
        XCTAssertEqual(fallback.syncPoints, 27)
        XCTAssertEqual(fallback.contributors, cached.contributors)
    }

    func testKaraokeBouncePolicyHonorsTimingAndReduceMotionBoundaries() {
        XCTAssertFalse(KaraokeBouncePolicy.isWindowActive(
            positionMs: 99,
            lineStartTimeMs: 100,
            lineEndTimeMs: 600,
            bounceEnabled: true,
            reduceMotion: false,
            hasSegments: true
        ))
        XCTAssertTrue(KaraokeBouncePolicy.isWindowActive(
            positionMs: 879,
            lineStartTimeMs: 100,
            lineEndTimeMs: 600,
            bounceEnabled: true,
            reduceMotion: false,
            hasSegments: true
        ))
        XCTAssertFalse(KaraokeBouncePolicy.isWindowActive(
            positionMs: 880,
            lineStartTimeMs: 100,
            lineEndTimeMs: 600,
            bounceEnabled: true,
            reduceMotion: false,
            hasSegments: true
        ))
        XCTAssertFalse(KaraokeBouncePolicy.isWindowActive(
            positionMs: 300,
            lineStartTimeMs: 100,
            lineEndTimeMs: 600,
            bounceEnabled: true,
            reduceMotion: true,
            hasSegments: true
        ))

        XCTAssertNil(KaraokeBouncePolicy.strength(positionMs: 99, startTimeMs: 100, endTimeMs: 600))
        XCTAssertEqual(KaraokeBouncePolicy.strength(positionMs: 100, startTimeMs: 100, endTimeMs: 600), 0)
        XCTAssertGreaterThan(KaraokeBouncePolicy.strength(positionMs: 300, startTimeMs: 100, endTimeMs: 600) ?? 0, 0)
        XCTAssertEqual(KaraokeBouncePolicy.strength(positionMs: 600, startTimeMs: 100, endTimeMs: 600), 1)
        XCTAssertGreaterThan(KaraokeBouncePolicy.strength(positionMs: 700, startTimeMs: 100, endTimeMs: 600) ?? 0, 0)
        XCTAssertNil(KaraokeBouncePolicy.strength(positionMs: 825, startTimeMs: 100, endTimeMs: 600))
    }
}
