import CryptoKit
import Foundation

public struct LyricsProviderSettingsSnapshot: Sendable {
    public let mode: LyricsProviderMode
    public let enabledProviders: Set<LyricsProviderID>
    public let providerOrder: [LyricsProviderID]
    public let deezerConfigured: Bool
    public let remoteDisabledProviders: Set<LyricsProviderID>
    public let globalRemoteDisable: Bool
    public let policyVersion: Int
    public let credentialGeneration: UInt64

    public init(mode: LyricsProviderMode = .legacy,
                enabledProviders: Set<LyricsProviderID> = Set(LyricsProviderID.defaultOrder),
                providerOrder: [LyricsProviderID] = LyricsProviderID.defaultOrder,
                deezerConfigured: Bool = false,
                remoteDisabledProviders: Set<LyricsProviderID> = [],
                globalRemoteDisable: Bool = false, policyVersion: Int = 1,
                credentialGeneration: UInt64 = 0) {
        self.mode = mode
        self.enabledProviders = enabledProviders
        self.providerOrder = providerOrder
        self.deezerConfigured = deezerConfigured
        self.remoteDisabledProviders = remoteDisabledProviders
        self.globalRemoteDisable = globalRemoteDisable
        self.policyVersion = policyVersion
        self.credentialGeneration = credentialGeneration
    }
}

public struct EffectiveProviderPolicy: Codable, Hashable, Sendable {
    public let effectiveMode: LyricsProviderMode
    public let deniedProviders: Set<LyricsProviderID>
    public let orderedProviders: [LyricsProviderID]
    public let policyVersion: Int
    public let credentialGeneration: UInt64

    public init(effectiveMode: LyricsProviderMode, deniedProviders: Set<LyricsProviderID>,
                orderedProviders: [LyricsProviderID], policyVersion: Int,
                credentialGeneration: UInt64) {
        self.effectiveMode = effectiveMode
        self.deniedProviders = deniedProviders
        self.orderedProviders = orderedProviders
        self.policyVersion = policyVersion
        self.credentialGeneration = credentialGeneration
    }

    public func allows(_ provider: LyricsProviderID) -> Bool {
        !deniedProviders.contains(provider) && orderedProviders.contains(provider)
    }
}

public enum LyricsProviderPolicyEvaluator {
    public static func evaluate(_ snapshot: LyricsProviderSettingsSnapshot,
                                multiProviderAuthorized: Bool) -> EffectiveProviderPolicy {
        let mode: LyricsProviderMode = snapshot.globalRemoteDisable
            ? .legacy
            : (snapshot.mode == .multiProvider && multiProviderAuthorized ? .multiProvider : .legacy)
        let denied = snapshot.remoteDisabledProviders
        var enabled = snapshot.enabledProviders.subtracting(denied)
        if !snapshot.deezerConfigured { enabled.remove(.deezer) }
        let ordered = canonicalProviderOrder(snapshot.providerOrder, enabled: enabled)
        return EffectiveProviderPolicy(effectiveMode: mode, deniedProviders: denied,
                                       orderedProviders: ordered,
                                       policyVersion: snapshot.policyVersion,
                                       credentialGeneration: snapshot.credentialGeneration)
    }

    public static func canonicalProviderOrder(_ order: [LyricsProviderID],
                                              enabled: Set<LyricsProviderID>) -> [LyricsProviderID] {
        var seen = Set<LyricsProviderID>()
        var result = order.filter { enabled.contains($0) && seen.insert($0).inserted }
        result.append(contentsOf: LyricsProviderID.defaultOrder.filter {
            enabled.contains($0) && seen.insert($0).inserted
        })
        // Future provider IDs cannot exist without a new enum case; sorting keeps this deterministic
        // if the fixed list and enum evolve independently.
        result.append(contentsOf: enabled.filter { seen.insert($0).inserted }.sorted { $0.rawValue < $1.rawValue })
        return result
    }
}

public struct LyricsProviderRemotePolicy: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let globalDisable: Bool
    public let disabledProviders: Set<LyricsProviderID>
    public let multiProviderCohortAllowed: Bool
    public let policyVersion: Int
    public let expiresAtMs: Int64?

    public init(schemaVersion: Int, globalDisable: Bool,
                disabledProviders: Set<LyricsProviderID>,
                multiProviderCohortAllowed: Bool, policyVersion: Int,
                expiresAtMs: Int64? = nil) {
        self.schemaVersion = schemaVersion
        self.globalDisable = globalDisable
        self.disabledProviders = disabledProviders
        self.multiProviderCohortAllowed = multiProviderCohortAllowed
        self.policyVersion = policyVersion
        self.expiresAtMs = expiresAtMs
    }
}

public enum RemotePolicySigner {
    public static func verify(payload: Data, signature: Data,
                              publicKeyRawRepresentation: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRawRepresentation) else {
            return false
        }
        return key.isValidSignature(signature, for: payload)
    }
}

public enum LyricsProviderRemotePolicyDecoder {
    public static func decode(payload: Data, signature: Data,
                              publicKeyRawRepresentation: Data,
                              nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> LyricsProviderRemotePolicy? {
        guard RemotePolicySigner.verify(payload: payload, signature: signature,
                                        publicKeyRawRepresentation: publicKeyRawRepresentation),
              let policy = try? JSONDecoder().decode(LyricsProviderRemotePolicy.self, from: payload),
              policy.schemaVersion == 1,
              policy.expiresAtMs.map({ $0 > nowMs }) ?? true else { return nil }
        return policy
    }
}
