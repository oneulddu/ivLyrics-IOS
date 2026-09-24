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

    func testTrackSelectionChangesPolicyWithoutChangingGlobalPreferences() {
        let suiteName = "TrackProviderSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let original = settings.snapshot
        let generation = original.lyricsProviderPolicyGeneration

        settings.selectLyricsProvider("paxsenix", trackKey: "song-a")
        let selected = settings.snapshotForTrack("song-a")
        XCTAssertEqual(settings.selectedLyricsProvider(trackKey: "song-a"), "paxsenix")
        XCTAssertEqual(selected.enabledStandardLyricsProviderOrder, ["paxsenix"])
        XCTAssertTrue(selected.standardLyricsProviderTypes["paxsenix"]!.values.allSatisfy { $0 })
        XCTAssertFalse(selected.standardPreferSyncDataProvider)
        XCTAssertTrue(selected.standardPreferLyricsTypeOverProviderOrder)
        XCTAssertEqual(settings.snapshot.lyricsProviderPolicyGeneration, generation + 1)
        XCTAssertEqual(settings.snapshot.standardLyricsProviderPolicySignature, original.standardLyricsProviderPolicySignature)
        XCTAssertEqual(settings.snapshotForTrack("song-b").standardLyricsProviderPolicySignature, original.standardLyricsProviderPolicySignature)
        XCTAssertEqual(selected.standardLyricsProviderPolicySignature, settings.snapshotForTrack("song-a").standardLyricsProviderPolicySignature)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.selectedLyricsProvider(trackKey: "song-a"), "paxsenix")
        settings.selectLyricsProvider("", trackKey: "song-a")
        XCTAssertNil(defaults.string(forKey: "track_lyrics_provider.song-a"))
        XCTAssertEqual(settings.snapshotForTrack("song-a").standardLyricsProviderPolicySignature, original.standardLyricsProviderPolicySignature)
    }

    func testTrackSelectionRetainsInapplicableProviderAcrossModeChanges() {
        let suiteName = "TrackProviderMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.selectLyricsProvider("bugs", trackKey: "song")
        XCTAssertEqual(defaults.string(forKey: "track_lyrics_provider.song"), "bugs")
        XCTAssertEqual(settings.selectedLyricsProvider(trackKey: "song"), "")
        XCTAssertEqual(settings.lyricsProviderModeRaw, "legacy")

        settings.lyricsProviderModeRaw = "multiProvider"
        XCTAssertEqual(settings.selectedLyricsProvider(trackKey: "song"), "bugs")
        XCTAssertEqual(settings.snapshotForTrack("song").lyricsProviderSettings.enabledProviders, [.bugs])
        settings.lyricsProviderModeRaw = "legacy"
        XCTAssertEqual(settings.selectedLyricsProvider(trackKey: "song"), "")
        XCTAssertEqual(defaults.string(forKey: "track_lyrics_provider.song"), "bugs")
    }

    func testTrackSnapshotPreservesRemotePolicyAndAuthorization() {
        let suiteName = "TrackProviderPolicy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var snapshot = AppSettings(defaults: defaults).snapshot
        snapshot.lyricsProviderMultiProviderAuthorized = true
        snapshot.lyricsProviderSettings = .init(
            mode: .multiProvider,
            enabledProviders: [.lrclib],
            providerOrder: [.bugs, .lrclib],
            remoteDisabledProviders: [.genie],
            policyVersion: 42,
            credentialGeneration: 7,
            allowedTypesByProvider: [.bugs: .init(karaoke: false, synced: false, plain: false)]
        )
        let selected = snapshot.selectingLyricsProvider("bugs")
        let policy = LyricsProviderPolicyEvaluator.evaluate(selected.lyricsProviderSettings, multiProviderAuthorized: selected.lyricsProviderMultiProviderAuthorized)
        XCTAssertEqual(policy.orderedProviders, [.bugs])
        XCTAssertEqual(policy.allowedTypes(for: .bugs), .allowAll)
        XCTAssertEqual(policy.policyVersion, 42)
        XCTAssertEqual(policy.credentialGeneration, 7)
        XCTAssertEqual(policy.deniedProviders, [.genie])
        XCTAssertFalse(selected.lyricsProviderSettings.deezerConfigured)
        XCTAssertFalse(selected.lyricsProviderSettings.globalRemoteDisable)
        for unavailable in ["genie", "deezer"] {
            XCTAssertFalse(snapshot.trackLyricsProviderOptions.contains { $0.id == unavailable })
            XCTAssertEqual(snapshot.selectingLyricsProvider(unavailable).lyricsProviderSettings.enabledProviders, [.lrclib])
        }
        snapshot.lyricsProviderMultiProviderAuthorized = false
        XCTAssertFalse(snapshot.selectingLyricsProvider("bugs").lyricsProviderMultiProviderAuthorized)
        XCTAssertEqual(snapshot.selectingLyricsProvider("bugs").lyricsProviderSettings.enabledProviders, [.lrclib])
        snapshot.lyricsProviderSettings = .init(mode: .multiProvider, globalRemoteDisable: true)
        snapshot.standardLyricsProviderRemoteGlobalDisable = true
        XCTAssertEqual(snapshot.trackLyricsProviderOptions.map(\.id), ["lrclib"])
        XCTAssertEqual(snapshot.selectingLyricsProvider("paxsenix").enabledStandardLyricsProviderOrder, ["lrclib"])
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
