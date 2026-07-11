import Foundation

private var failures: [String] = []

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

expect(LyricsProviderAppContracts.orderedLineIndices(
    starts: [0, 0, 0], timingIsPlain: true
) == [0, 1, 2], "plain lyrics must preserve provider line order")
expect(LyricsProviderAppContracts.orderedLineIndices(
    starts: [2_000, 1_000, 1_000, 3_000], timingIsPlain: false
) == [1, 2, 0, 3], "line-synced lyrics must use a stable time sort")

for provider in ["LRCLIB", "Musixmatch", "Deezer", "Bugs", "Genie"] {
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
