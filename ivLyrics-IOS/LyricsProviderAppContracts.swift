import Foundation

struct CachedLyricsProviderRemotePolicy: Codable, Equatable {
    var globalDisable: Bool
    var disabledProviderIDs: Set<String>
    var cohortAllowed: Bool
    var policyVersion: Int
    var expiresAtMs: Int64
}

enum LyricsProviderAppContracts {
    static func multiProviderAuthorized(
        internalBuild: Bool,
        explicitLocalOptIn: Bool,
        verifiedCohort: Bool
    ) -> Bool {
        internalBuild || explicitLocalOptIn || verifiedCohort
    }

    static func multiProviderRequested(
        explicitLocalOptIn: Bool,
        verifiedCohort: Bool
    ) -> Bool {
        explicitLocalOptIn || verifiedCohort
    }

    static func policyAfterVerification(
        current: CachedLyricsProviderRemotePolicy?,
        verified: CachedLyricsProviderRemotePolicy?
    ) -> CachedLyricsProviderRemotePolicy? {
        verified ?? current
    }

    static func restoredPolicy(
        _ cached: CachedLyricsProviderRemotePolicy,
        nowMs: Int64
    ) -> CachedLyricsProviderRemotePolicy {
        guard cached.expiresAtMs <= nowMs else { return cached }
        var failClosed = cached
        failClosed.cohortAllowed = false
        return failClosed
    }

    static func requestStillAuthorized(
        requestGeneration: UInt64,
        currentGeneration: UInt64,
        effectiveModeIsMultiProvider: Bool,
        selectedProviderIsAllowed: Bool
    ) -> Bool {
        requestGeneration == currentGeneration
            && effectiveModeIsMultiProvider
            && selectedProviderIsAllowed
    }

    static func orderedLineIndices(
        starts: [Int64],
        timingIsPlain: Bool
    ) -> [Int] {
        guard !timingIsPlain else { return Array(starts.indices) }
        return starts.indices.sorted { left, right in
            if starts[left] != starts[right] { return starts[left] < starts[right] }
            return left < right
        }
    }

    static func providerBaseLabel(
        providerName: String,
        lineSynced: Bool,
        syncDataApplied: Bool
    ) -> String {
        syncDataApplied
            ? "ivLyrics sync-data + \(providerName)"
            : "\(providerName) \(lineSynced ? "synced" : "plain")"
    }
}
