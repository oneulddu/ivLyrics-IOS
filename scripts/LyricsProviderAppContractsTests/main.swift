import Foundation

nonisolated(unsafe) private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

private let restrictive = CachedLyricsProviderRemotePolicy(
    globalDisable: true,
    disabledProviderIDs: ["bugs", "genie"],
    cohortAllowed: true,
    policyVersion: 7,
    expiresAtMs: 2_000
)

expect(LyricsProviderAppContracts.multiProviderAuthorized(
    internalBuild: false, explicitLocalOptIn: true, verifiedCohort: false
), "explicit local opt-in must authorize multi-provider")
expect(LyricsProviderAppContracts.multiProviderAuthorized(
    internalBuild: false, explicitLocalOptIn: false, verifiedCohort: true
), "verified cohort must authorize multi-provider")
expect(LyricsProviderAppContracts.multiProviderAuthorized(
    internalBuild: true, explicitLocalOptIn: false, verifiedCohort: false
), "internal build must authorize an explicit request")

let debugFreshInstallRequestedMulti = LyricsProviderAppContracts.multiProviderRequested(
    explicitLocalOptIn: false, verifiedCohort: false
)
let debugFreshInstallAuthorized = LyricsProviderAppContracts.multiProviderAuthorized(
    internalBuild: true, explicitLocalOptIn: false, verifiedCohort: false
)
expect(!debugFreshInstallRequestedMulti && debugFreshInstallAuthorized,
       "DEBUG fresh install must remain legacy while retaining internal authorization")

expect(LyricsProviderAppContracts.policyAfterVerification(
    current: restrictive, verified: nil
) == restrictive, "invalid or expired payload must not clear the current stop policy")

let expired = LyricsProviderAppContracts.restoredPolicy(restrictive, nowMs: 2_000)
expect(expired.globalDisable, "expired cache must retain global disable")
expect(expired.disabledProviderIDs == restrictive.disabledProviderIDs,
       "expired cache must retain provider denylist")
expect(!expired.cohortAllowed, "expired cache must revoke cohort authorization")
let cacheRoundTrip = try JSONDecoder().decode(
    CachedLyricsProviderRemotePolicy.self,
    from: JSONEncoder().encode(restrictive)
)
expect(cacheRoundTrip == restrictive, "verified policy cache must preserve expiry and restrictions")

expect(!LyricsProviderAppContracts.requestStillAuthorized(
    requestGeneration: 4, currentGeneration: 5,
    effectiveModeIsMultiProvider: true, selectedProviderIsAllowed: true
), "policy generation change must reject an in-flight result")
expect(!LyricsProviderAppContracts.requestStillAuthorized(
    requestGeneration: 5, currentGeneration: 5,
    effectiveModeIsMultiProvider: false, selectedProviderIsAllowed: true
), "global downgrade must reject a multi-provider result")
expect(!LyricsProviderAppContracts.requestStillAuthorized(
    requestGeneration: 5, currentGeneration: 5,
    effectiveModeIsMultiProvider: true, selectedProviderIsAllowed: false
), "denylisted provider result must be rejected")

expect(LyricsProviderAppContracts.cachePreviewStillAuthorized(
    requestGeneration: 8, currentGeneration: 8,
    requestEffectiveMode: "legacy", currentEffectiveMode: "legacy",
    baseProviderIsAllowed: true
), "an unchanged legacy LRCLIB preview must remain valid")
expect(!LyricsProviderAppContracts.cachePreviewStillAuthorized(
    requestGeneration: 8, currentGeneration: 9,
    requestEffectiveMode: "multiProvider", currentEffectiveMode: "multiProvider",
    baseProviderIsAllowed: true
), "a stale cache preview generation must be rejected")
expect(!LyricsProviderAppContracts.cachePreviewStillAuthorized(
    requestGeneration: 8, currentGeneration: 8,
    requestEffectiveMode: "multiProvider", currentEffectiveMode: "legacy",
    baseProviderIsAllowed: true
), "a cache preview from a superseded effective mode must be rejected")
expect(!LyricsProviderAppContracts.cachePreviewStillAuthorized(
    requestGeneration: 8, currentGeneration: 8,
    requestEffectiveMode: "multiProvider", currentEffectiveMode: "multiProvider",
    baseProviderIsAllowed: false
), "a cache preview from a newly denied base provider must be rejected")

expect(LyricsProviderAppContracts.orderedLineIndices(
    starts: [0, 0, 0], timingIsPlain: true
) == [0, 1, 2], "plain lyrics must preserve provider line order")
expect(LyricsProviderAppContracts.orderedLineIndices(
    starts: [2_000, 1_000, 1_000, 3_000], timingIsPlain: false
) == [1, 2, 0, 3], "line-synced lyrics must use a stable time sort")

expect(LyricsProviderAppContracts.providerOrderRawValues == [
    "musixmatch", "deezer", "unison", "bugs", "genie", "lrclib"
], "provider order must include Unison at its fixed position")
expect(LyricsProviderAppContracts.canonicalProviderOrder(
    ["musixmatch", "deezer", "bugs", "genie", "lrclib"]
) == ["musixmatch", "deezer", "unison", "bugs", "genie", "lrclib"],
       "existing saved orders must insert Unison at the fixed position")
expect(LyricsProviderAppContracts.canonicalProviderOrder(
    ["bugs", "bugs", "unknown", "lrclib"]
) == ["musixmatch", "deezer", "unison", "bugs", "genie", "lrclib"],
       "provider order must remove duplicates and unknown IDs")
expect(LyricsProviderAppContracts.canonicalProviderOrder(
    ["lrclib", "bugs", "musixmatch"]
) == ["deezer", "unison", "genie", "lrclib", "bugs", "musixmatch"],
       "normalization must preserve the relative order of existing providers")
expect(LyricsProviderAppContracts.defaultEnabledProviderRawValues == ["lrclib"],
       "fresh installs must keep only LRCLIB enabled")
expect(LyricsProviderAppContracts.unofficialProviderRawValues.contains("unison"),
       "Unison must be exposed as an opt-in unofficial provider")
expect(LyricsProviderAppContracts.providerDisplayName("unison") == "Unison",
       "Unison display name must be stable")

let standardDefaults = LyricsProviderAppContracts.standardEffectiveProviderStates(
    order: LyricsProviderAppContracts.standardProviderOrderRawValues,
    enabled: [:],
    remoteGlobalDisable: false
)
expect(standardDefaults.order == ["lrclib"],
       "fresh installs must enable only the standard LRCLIB provider")
expect(Set(standardDefaults.enabled.filter(\.value).map(\.key)) == ["lrclib"],
       "standard enabled defaults must agree with the effective order")

let standardOptIn = LyricsProviderAppContracts.standardEffectiveProviderStates(
    order: ["lyricsplus", "unison", "lrclib"],
    enabled: ["lrclib": true, "lyricsplus": true, "unison": true],
    remoteGlobalDisable: false
)
let standardKilled = LyricsProviderAppContracts.standardEffectiveProviderStates(
    order: ["lyricsplus", "unison", "lrclib"],
    enabled: ["lrclib": true, "lyricsplus": true, "unison": true],
    remoteGlobalDisable: true
)
expect(standardKilled.order == ["lrclib"],
       "remote global disable must force the standard provider order to LRCLIB only")
expect(standardKilled.signatureComponent != standardOptIn.signatureComponent,
       "standard policy signature must change when the remote kill-switch flips")

let standardToggled = LyricsProviderAppContracts.standardEffectiveProviderStates(
    order: LyricsProviderAppContracts.standardProviderOrderRawValues,
    enabled: ["lrclib": true, "lyricsplus": true],
    remoteGlobalDisable: false
)
expect(standardToggled.signatureComponent != standardDefaults.signatureComponent,
       "standard policy signature must change when a provider is toggled")

expect(LyricsProviderAppContracts.shouldPreserveProviderKaraoke(
    providerID: "unison",
    lineSyllableDurationsMs: [[500, 500]],
    vocalPartSyllableDurationsMs: []
), "Unison line syllable timing must be preserved as karaoke")
expect(LyricsProviderAppContracts.shouldPreserveProviderKaraoke(
    providerID: "unison",
    lineSyllableDurationsMs: [],
    vocalPartSyllableDurationsMs: [[[1_000], [750]]]
), "Unison lead/background vocal timing must be preserved as karaoke")
expect(!LyricsProviderAppContracts.shouldPreserveProviderKaraoke(
    providerID: "unison",
    lineSyllableDurationsMs: [[], []],
    vocalPartSyllableDurationsMs: []
), "Unison LRC/plain lines must not be misclassified as rich timing")
expect(!LyricsProviderAppContracts.shouldPreserveProviderKaraoke(
    providerID: "bugs",
    lineSyllableDurationsMs: [[500]],
    vocalPartSyllableDurationsMs: []
), "rich timing preservation must remain scoped to Unison")

for provider in ["LRCLIB", "Musixmatch", "Deezer", "Unison", "Bugs", "Genie"] {
    expect(LyricsProviderAppContracts.providerBaseLabel(
        providerName: provider, lineSynced: false, syncDataApplied: false
    ) == "\(provider) plain", "plain provider label mismatch for \(provider)")
    expect(LyricsProviderAppContracts.providerBaseLabel(
        providerName: provider, lineSynced: true, syncDataApplied: false
    ) == "\(provider) synced", "synced provider label mismatch for \(provider)")
    expect(LyricsProviderAppContracts.providerBaseLabel(
        providerName: provider, lineSynced: true, syncDataApplied: true
    ) == "ivLyrics sync-data + \(provider)", "sync-data provider label mismatch for \(provider)")
}

if failures.isEmpty {
    print("LyricsProviderAppContractsTests: PASS")
} else {
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    exit(1)
}
