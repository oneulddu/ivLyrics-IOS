import LyricsProviderCore
import XCTest
@testable import ivLyrics_IOS

final class LyricsProviderModeParityTests: XCTestCase {
    func testMultiPreferencesInitiallyInheritStandardValuesAndThenPersistSeparately() {
        let suiteName = "LyricsProviderModeParityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "lyrics_prefer_sync_data_provider")
        defaults.set(false, forKey: "lyrics_prefer_type_over_provider")

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.multiPreferSyncDataProvider)
        XCTAssertFalse(settings.multiPreferLyricsTypeOverProviderOrder)

        settings.multiPreferSyncDataProvider = true
        settings.multiPreferLyricsTypeOverProviderOrder = true
        XCTAssertFalse(settings.standardPreferSyncDataProvider)
        XCTAssertFalse(settings.standardPreferLyricsTypeOverProviderOrder)
        XCTAssertTrue(settings.snapshot.lyricsProviderSettings.preferSyncDataProvider)
        XCTAssertTrue(settings.snapshot.lyricsProviderSettings.preferLyricsTypeOverProviderOrder)
    }

    func testInheritedMultiPreferencesArePersistedBeforeStandardValuesChange() {
        let suiteName = "LyricsProviderModeParityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "lyrics_prefer_sync_data_provider")
        defaults.set(false, forKey: "lyrics_prefer_type_over_provider")

        var settings: AppSettings? = AppSettings(defaults: defaults)
        XCTAssertFalse(settings?.multiPreferSyncDataProvider ?? true)
        XCTAssertFalse(settings?.multiPreferLyricsTypeOverProviderOrder ?? true)

        settings?.standardPreferSyncDataProvider = true
        settings?.standardPreferLyricsTypeOverProviderOrder = true
        settings = nil

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.multiPreferSyncDataProvider)
        XCTAssertFalse(reloaded.multiPreferLyricsTypeOverProviderOrder)
    }

    func testMultiProviderModeDoesNotForceLrclibEnabled() {
        let suiteName = "LyricsProviderModeParityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("multiProvider", forKey: "lyrics_provider_mode")
        defaults.set([], forKey: "lyrics_provider_enabled")

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.snapshot.lyricsProviderSettings.enabledProviders.isEmpty)
    }

    func testAppProviderAdapterPreservesRichTimingAndNeutralEvidence() throws {
        let request = LyricsProviderRequest(
            trackKey: "track",
            title: "Signal",
            artist: "Alpha",
            album: "Album",
            durationMs: 180_000,
            isrc: "USRC17607839"
        )
        let richLine = LyricsLine(
            startTimeMs: 1_000,
            endTimeMs: 2_000,
            text: "Signal",
            syllables: [.init(text: "Sig", startTimeMs: 1_000, endTimeMs: 1_500)],
            speaker: "A",
            speakerColor: "#ffffff",
            vocalParts: [
                .init(
                    id: "background-1",
                    role: "background",
                    speaker: "B",
                    kind: "vocal",
                    text: "nal",
                    syllables: [.init(text: "nal", startTimeMs: 1_500, endTimeMs: 2_000)]
                )
            ]
        )

        let result = try AppLyricsProviderAdapterSupport.providerLyrics(
            provider: .paxsenix,
            request: request,
            sourceType: "fixture",
            karaoke: [richLine],
            synced: nil,
            plain: nil
        )

        XCTAssertEqual(result.provider, .paxsenix)
        XCTAssertEqual(result.timing, .lineSynced)
        XCTAssertEqual(result.matchedCandidate.matchEvidence.totalScore, 0)
        XCTAssertEqual(result.matchedCandidate.matchEvidence.directIdentifier, .none)
        XCTAssertEqual(result.lines.first?.speaker?.speaker, "A")
        XCTAssertEqual(result.lines.first?.vocalParts.first?.role, .background)
        XCTAssertTrue(result.lines.contains { line in
            line.syllables.contains { $0.endMs > $0.startMs }
                || line.vocalParts.contains { part in
                    part.syllables.contains { $0.endMs > $0.startMs }
                }
        })
    }
}
