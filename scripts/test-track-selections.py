#!/usr/bin/env python3
"""Exercise the production URL, community timing, and per-track provider policy code."""
from pathlib import Path
import subprocess,tempfile
src=Path(__file__).resolve().parents[1]/'ivLyrics-IOS'
video=(src/'YouTubeBackgroundRepository.swift').read_text()
models=(src/'Models.swift').read_text()
settings=(src/'AppSettings.swift').read_text()
policy=settings[settings.index('        private var standardEffectiveProviderStates:'):settings.index('        var enabled: Bool', settings.index('        private var standardEffectiveProviderStates:'))]
core=src.parent/'LyricsProviderCore/Sources/LyricsProviderCore'
core_models=(core/'LyricsProviderModels.swift').read_text().split('public enum DirectIdentifierEvidence:')[0]
core_policy=(core/'LyricsProviderPolicy.swift').read_text().split('public struct LyricsProviderRemotePolicy:')[0]
code='import Foundation\nextension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }\nenum TrackSnapshot { static func normalizeIsrc(_ s: String) -> String { s.uppercased() } }\n'
code+=models[models.index('struct YouTubeVideoInfo:'):models.index('struct SpotifyResolvedTrack:')]
code+=video[video.index('extension YouTubeVideoInfo {'):].replace('nonisolated enum','enum')
code+=core_models+core_policy+(src/'LyricsProviderAppContracts.swift').read_text()
code+='''
final class AppSettings {
    static let standardDefaultLyricsProviderOrder = ["lrclib", "paxsenix", "lyricsplus", "unison"]
    static let standardLyricsTypeKaraoke = "karaoke", standardLyricsTypeSynced = "synced", standardLyricsTypePlain = "plain"
    struct StandardLyricsProvider { var name: String }
    static func standardLyricsProviderById(_ id: String) -> StandardLyricsProvider? { standardDefaultLyricsProviderOrder.contains(id) ? StandardLyricsProvider(name: id) : nil }
    static func normalizedStandardLyricsProviderOrder(_ ids: [String]) -> [String] { ids + standardDefaultLyricsProviderOrder.filter { !ids.contains($0) } }
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    struct Publisher { func send() {} }
    let objectWillChange = Publisher()
    var snapshot = Snapshot()
    func recordLyricsProviderPolicyChange() { snapshot.lyricsProviderPolicyGeneration += 1 }
'''+settings[settings.index('    struct TrackLyricsProviderOption:'):settings.index('    var snapshot: Snapshot {')]+'''
    struct Snapshot {
        var standardLyricsProviderOrder = standardDefaultLyricsProviderOrder
        var standardLyricsProviderEnabled = ["lrclib": true, "paxsenix": false, "lyricsplus": true, "unison": true]
        var standardLyricsProviderTypes = ["paxsenix": ["karaoke": false, "synced": false, "plain": false]]
        var standardPreferSyncDataProvider = true
        var standardPreferLyricsTypeOverProviderOrder = false
        var standardLyricsProviderRemoteGlobalDisable = false
        var lyricsProviderSettings = LyricsProviderSettingsSnapshot()
        var lyricsProviderMultiProviderAuthorized = false
        var lyricsProviderPolicyGeneration: UInt64 = 0
'''+policy+'''    }
}
@main struct Checks {
    static func main() throws {
        let id = "Abc_123-xy"
        let videoID = "Abc_123-xyz"
        for value in [videoID, "https://youtu.be/" + videoID, "https://www.youtube.com/watch?v=" + videoID + "&t=12", "https://m.youtube.com/shorts/" + videoID] {
            precondition(YouTubeVideoSelection.extractId(value) == videoID)
        }
        for value in [id, "https://youtube.com.evil.test/watch?v=" + videoID, "javascript:" + videoID, "https://youtu.be/a/b", "https://youtube.com/embed/../" + videoID] {
            precondition(YouTubeVideoSelection.extractId(value) == nil)
        }
        let info = YouTubeVideoInfo.fromJson(fallbackIsrc: "", object: ["videoId": videoID, "startTime": 12.5])!
        precondition(info.isrc.isEmpty && info.hasCaptionStartTime && info.captionStartTimeSeconds == 12.5)
        precondition(try JSONDecoder().decode(YouTubeVideoInfo.self, from: JSONEncoder().encode(info)) == info)
        let original = AppSettings.Snapshot()
        let selected = original.selectingLyricsProvider("paxsenix")
        precondition(selected.enabledStandardLyricsProviderOrder == ["paxsenix"])
        precondition(selected.standardLyricsProviderTypes["paxsenix"]!.values.allSatisfy { $0 })
        precondition(!selected.standardPreferSyncDataProvider && selected.standardPreferLyricsTypeOverProviderOrder)
        precondition(original.standardLyricsProviderEnabled["paxsenix"] == false)
        precondition(original.selectingLyricsProvider("").enabledStandardLyricsProviderOrder == original.enabledStandardLyricsProviderOrder)
        var multi = original
        multi.lyricsProviderMultiProviderAuthorized = true
        multi.lyricsProviderSettings = LyricsProviderSettingsSnapshot(mode: .multiProvider, enabledProviders: [.lrclib], providerOrder: [.bugs, .lrclib], remoteDisabledProviders: [.genie], policyVersion: 9, credentialGeneration: 17, allowedTypesByProvider: [.bugs: .init(karaoke: false, synced: false, plain: false)])
        let picked = multi.selectingLyricsProvider("bugs")
        let policy = LyricsProviderPolicyEvaluator.evaluate(picked.lyricsProviderSettings, multiProviderAuthorized: picked.lyricsProviderMultiProviderAuthorized)
        precondition(policy.effectiveMode == .multiProvider && policy.orderedProviders == [.bugs])
        precondition(policy.allowedTypes(for: .bugs) == .allowAll && !policy.preferSyncDataProvider && policy.preferLyricsTypeOverProviderOrder)
        precondition(picked.lyricsProviderSettings.remoteDisabledProviders == [.genie] && !picked.lyricsProviderSettings.deezerConfigured)
        precondition(policy.policyVersion == 9 && policy.credentialGeneration == 17)
        precondition(multi.lyricsProviderSettings.enabledProviders == [.lrclib])
        precondition(!multi.trackLyricsProviderOptions.contains { $0.id == "genie" || $0.id == "deezer" })
        precondition(multi.selectingLyricsProvider("genie").lyricsProviderSettings.enabledProviders == [.lrclib])
        precondition(multi.selectingLyricsProvider("deezer").lyricsProviderSettings.enabledProviders == [.lrclib])
        precondition(original.selectingLyricsProvider("bugs").standardLyricsProviderPolicySignature == original.standardLyricsProviderPolicySignature)
        multi.lyricsProviderMultiProviderAuthorized = false
        precondition(multi.selectingLyricsProvider("bugs").lyricsProviderSettings.enabledProviders == [.lrclib])
        precondition(!multi.selectingLyricsProvider("paxsenix").lyricsProviderMultiProviderAuthorized)
        var stopped = original
        stopped.standardLyricsProviderRemoteGlobalDisable = true
        stopped.lyricsProviderSettings = .init(mode: .multiProvider, remoteDisabledProviders: [.unison], globalRemoteDisable: true)
        precondition(stopped.trackLyricsProviderOptions.map(\.id) == ["lrclib"])
        precondition(stopped.selectingLyricsProvider("paxsenix").enabledStandardLyricsProviderOrder == ["lrclib"])
        var denied = original
        denied.lyricsProviderSettings = .init(remoteDisabledProviders: [.paxsenix])
        precondition(denied.selectingLyricsProvider("paxsenix").standardLyricsProviderPolicySignature == original.standardLyricsProviderPolicySignature)
        let suite = "TrackSelectionRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettings(defaults: defaults)
        store.selectLyricsProvider("bugs", trackKey: "song-a")
        precondition(defaults.string(forKey: "track_lyrics_provider.song-a") == "bugs")
        precondition(store.selectedLyricsProvider(trackKey: "song-a").isEmpty)
        precondition(store.snapshot.lyricsProviderPolicyGeneration == 1)
        multi.lyricsProviderMultiProviderAuthorized = true
        store.snapshot = multi
        precondition(store.selectedLyricsProvider(trackKey: "song-a") == "bugs")
        precondition(store.snapshotForTrack("song-a").lyricsProviderSettings.enabledProviders == [.bugs])
        precondition(store.snapshotForTrack("song-b").lyricsProviderSettings.enabledProviders == [.lrclib])
        store.snapshot = original
        store.selectLyricsProvider("paxsenix", trackKey: "song-b")
        precondition(store.snapshotForTrack("song-b").enabledStandardLyricsProviderOrder == ["paxsenix"])
        let signature = store.snapshotForTrack("song-b").standardLyricsProviderPolicySignature
        precondition(signature == store.snapshotForTrack("song-b").standardLyricsProviderPolicySignature)
        precondition(signature != store.snapshot.standardLyricsProviderPolicySignature)
        store.selectLyricsProvider("", trackKey: "song-b")
        precondition(store.snapshotForTrack("song-b").standardLyricsProviderPolicySignature == original.standardLyricsProviderPolicySignature)
        print("Track selection regression: URL validation, timing, persistence, provider isolation passed")
    }
}
'''
# Throwing work cannot be inside precondition's non-throwing autoclosure.
code=code.replace('precondition(try JSONDecoder().decode(YouTubeVideoInfo.self, from: JSONEncoder().encode(info)) == info)','let decoded = try JSONDecoder().decode(YouTubeVideoInfo.self, from: JSONEncoder().encode(info)); precondition(decoded == info)')
with tempfile.TemporaryDirectory(prefix='ivlyrics-track-selection-') as temp:
    p=Path(temp)/'Checks.swift';p.write_text(code)
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(p),'-o',temp+'/checks'],check=True)
    subprocess.run([temp+'/checks'],check=True)
