import Foundation

struct CachedLyricsProviderRemotePolicy: Codable, Equatable {
    var globalDisable: Bool
    var disabledProviderIDs: Set<String>
    var cohortAllowed: Bool
    var policyVersion: Int
    var expiresAtMs: Int64
}

struct StandardLyricsProviderStates: Equatable, Sendable {
    var order: [String]
    var enabled: [String: Bool]
    var signatureComponent: String
}

enum LyricsProviderAppContracts {
    static let providerOrderRawValues = ["musixmatch", "deezer", "unison", "bugs", "genie", "lrclib"]
    static let defaultEnabledProviderRawValues: Set<String> = ["lrclib"]
    static let unofficialProviderRawValues = ["musixmatch", "deezer", "unison", "bugs", "genie"]
    static let standardProviderOrderRawValues = ["lrclib", "paxsenix", "lyricsplus", "unison"]
    static let standardDefaultEnabledProviderRawValues: Set<String> = ["lrclib"]

    static func standardProviderEnabledDefault(_ providerID: String) -> Bool {
        standardDefaultEnabledProviderRawValues.contains(providerID)
    }

    static func standardEffectiveProviderStates(
        order storedOrder: [String],
        enabled storedEnabled: [String: Bool],
        remoteGlobalDisable: Bool
    ) -> StandardLyricsProviderStates {
        var seen = Set<String>()
        var normalizedOrder = storedOrder.filter {
            standardProviderOrderRawValues.contains($0) && seen.insert($0).inserted
        }
        normalizedOrder.append(contentsOf: standardProviderOrderRawValues.filter { seen.insert($0).inserted })

        var normalizedEnabled = Dictionary(uniqueKeysWithValues: standardProviderOrderRawValues.map {
            ($0, storedEnabled[$0] ?? standardProviderEnabledDefault($0))
        })
        if remoteGlobalDisable {
            normalizedEnabled = Dictionary(uniqueKeysWithValues: standardProviderOrderRawValues.map {
                ($0, $0 == "lrclib")
            })
        }
        let effectiveOrder = normalizedOrder.filter { normalizedEnabled[$0] == true }
        let enabledSignature = standardProviderOrderRawValues.map {
            "\($0):\(normalizedEnabled[$0] == true ? 1 : 0)"
        }.joined(separator: ",")
        let signatureComponent = "standard-state-v1|kill:\(remoteGlobalDisable ? 1 : 0)|order:\(normalizedOrder.joined(separator: ","))|enabled:\(enabledSignature)"
        return StandardLyricsProviderStates(
            order: effectiveOrder,
            enabled: normalizedEnabled,
            signatureComponent: signatureComponent
        )
    }

    static func canonicalProviderOrder(_ stored: [String]) -> [String] {
        var seen = Set<String>()
        var result = stored.filter {
            providerOrderRawValues.contains($0) && seen.insert($0).inserted
        }
        for (defaultIndex, provider) in providerOrderRawValues.enumerated().reversed() where !seen.contains(provider) {
            let following = providerOrderRawValues.dropFirst(defaultIndex + 1)
            if let insertionIndex = result.firstIndex(where: { following.contains($0) }) {
                result.insert(provider, at: insertionIndex)
            } else {
                result.append(provider)
            }
            seen.insert(provider)
        }
        return result
    }

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

    static func cachePreviewStillAuthorized(
        requestGeneration: UInt64,
        currentGeneration: UInt64,
        requestEffectiveMode: String,
        currentEffectiveMode: String,
        baseProviderIsAllowed: Bool
    ) -> Bool {
        requestGeneration == currentGeneration
            && requestEffectiveMode == currentEffectiveMode
            && baseProviderIsAllowed
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

    static func providerDisplayName(_ rawValue: String) -> String {
        switch rawValue {
        case "musixmatch": return "Musixmatch"
        case "deezer": return "Deezer"
        case "unison": return "Unison"
        case "bugs": return "Bugs"
        case "genie": return "Genie"
        default: return "LRCLIB"
        }
    }

    static func shouldPreserveProviderKaraoke(
        providerID: String,
        lineSyllableDurationsMs: [[Int64]],
        vocalPartSyllableDurationsMs: [[[Int64]]]
    ) -> Bool {
        guard providerID == "unison" else { return false }
        return lineSyllableDurationsMs.joined().contains(where: { $0 > 0 })
            || vocalPartSyllableDurationsMs.joined().joined().contains(where: { $0 > 0 })
    }
}
