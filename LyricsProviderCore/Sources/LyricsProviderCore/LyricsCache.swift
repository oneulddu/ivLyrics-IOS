import Foundation

public struct LyricsCacheKey: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let separator: Character = "|"

    public struct Components: Codable, Hashable, Sendable {
        public let schemaVersion: Int
        public let effectiveMode: LyricsProviderMode
        public let normalizedTrackIdentity: String
        public let providerPolicyVersion: Int
        public let enabledProviderSetCanonical: String
        public let preferredProviderOrderCanonical: String
        public let allowedProviderTypesCanonical: String
        public let credentialGeneration: UInt64

        public init(schemaVersion: Int, effectiveMode: LyricsProviderMode,
                    normalizedTrackIdentity: String, providerPolicyVersion: Int,
                    enabledProviderSetCanonical: String,
                    preferredProviderOrderCanonical: String,
                    allowedProviderTypesCanonical: String = "",
                    credentialGeneration: UInt64) {
            self.schemaVersion = schemaVersion
            self.effectiveMode = effectiveMode
            self.normalizedTrackIdentity = normalizedTrackIdentity
            self.providerPolicyVersion = providerPolicyVersion
            self.enabledProviderSetCanonical = enabledProviderSetCanonical
            self.preferredProviderOrderCanonical = preferredProviderOrderCanonical
            self.allowedProviderTypesCanonical = allowedProviderTypesCanonical
            self.credentialGeneration = credentialGeneration
        }
    }

    public let components: Components
    public var description: String { encoded }
    public var encoded: String {
        [String(components.schemaVersion), components.effectiveMode.rawValue,
         components.normalizedTrackIdentity, String(components.providerPolicyVersion),
         components.enabledProviderSetCanonical, components.preferredProviderOrderCanonical,
         components.allowedProviderTypesCanonical,
         String(components.credentialGeneration)].map(Self.escape).joined(separator: String(Self.separator))
    }

    public init(components: Components) { self.components = components }

    public init?(encoded: String) {
        guard let values = Self.splitEscaped(encoded), values.count == 8,
              let schema = Int(values[0]),
              let mode = LyricsProviderMode(rawValue: values[1]),
              let policy = Int(values[3]), let generation = UInt64(values[7]) else { return nil }
        components = Components(schemaVersion: schema, effectiveMode: mode,
                                normalizedTrackIdentity: values[2], providerPolicyVersion: policy,
                                enabledProviderSetCanonical: values[4],
                                preferredProviderOrderCanonical: values[5],
                                allowedProviderTypesCanonical: values[6],
                                credentialGeneration: generation)
    }

    public static func normalizedTrackIdentity(title: String, artist: String, album: String,
                                               durationMs: Int64?) -> String {
        let durationBucket = durationMs.map { String(max(0, $0) / 5_000) } ?? "unknown"
        return [LyricsMatcher.normalize(title), LyricsMatcher.normalize(artist),
                LyricsMatcher.normalize(album), durationBucket].map(escapeIdentity).joined(separator: "~")
    }

    public static func enabledProviderSetCanonical(_ providers: Set<LyricsProviderID>) -> String {
        providers.map(\.rawValue).sorted().joined(separator: ",")
    }

    public static func preferredProviderOrderCanonical(_ order: [LyricsProviderID],
                                                       enabled: Set<LyricsProviderID>) -> String {
        LyricsProviderPolicyEvaluator.canonicalProviderOrder(order, enabled: enabled)
            .map(\.rawValue).joined(separator: ",")
    }

    public static func allowedProviderTypesCanonical(
        _ types: [LyricsProviderID: ProviderAllowedLyricsTypes]
    ) -> String {
        LyricsProviderID.defaultOrder.map { provider in
            let allowed = types[provider] ?? .allowAll
            let bits = "\(allowed.karaoke ? 1 : 0)\(allowed.synced ? 1 : 0)\(allowed.plain ? 1 : 0)"
            return "\(provider.rawValue):\(bits)"
        }.joined(separator: ",")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: String(separator), with: "\\" + String(separator))
    }

    private static func escapeIdentity(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "~", with: "\\~")
    }

    private static func splitEscaped(_ value: String) -> [String]? {
        var result = [String](), current = "", escaping = false
        for character in value {
            if escaping { current.append(character); escaping = false }
            else if character == "\\" { escaping = true }
            else if character == separator { result.append(current); current = "" }
            else { current.append(character) }
        }
        guard !escaping else { return nil }
        result.append(current)
        return result
    }
}

public struct LyricsCacheProvenance: Codable, Hashable, Sendable {
    public let effectiveMode: LyricsProviderMode
    public let baseProvider: LyricsProviderID
    public let providerTrackID: String
    public let timing: LyricsTiming
    public let normalizedCandidateTitle: String
    public let normalizedCandidateArtist: String
    public let normalizedCandidateAlbum: String?
    public let candidateDurationMs: Int64?
    public let matchEvidence: MatchEvidence
    public let matchPolicyVersion: Int
    public let parserVersion: Int
    public let providerPolicyVersion: Int
    public let syncDataApplied: Bool
    public let fetchedAtMs: Int64

    public init(effectiveMode: LyricsProviderMode, baseProvider: LyricsProviderID,
                providerTrackID: String, timing: LyricsTiming,
                normalizedCandidateTitle: String, normalizedCandidateArtist: String,
                normalizedCandidateAlbum: String? = nil, candidateDurationMs: Int64? = nil,
                matchEvidence: MatchEvidence, matchPolicyVersion: Int, parserVersion: Int,
                providerPolicyVersion: Int, syncDataApplied: Bool, fetchedAtMs: Int64) {
        self.effectiveMode = effectiveMode
        self.baseProvider = baseProvider
        self.providerTrackID = providerTrackID
        self.timing = timing
        self.normalizedCandidateTitle = normalizedCandidateTitle
        self.normalizedCandidateArtist = normalizedCandidateArtist
        self.normalizedCandidateAlbum = normalizedCandidateAlbum
        self.candidateDurationMs = candidateDurationMs
        self.matchEvidence = matchEvidence
        self.matchPolicyVersion = matchPolicyVersion
        self.parserVersion = parserVersion
        self.providerPolicyVersion = providerPolicyVersion
        self.syncDataApplied = syncDataApplied
        self.fetchedAtMs = fetchedAtMs
    }
}

public struct LyricsCacheEnvelope<Result: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let cacheKey: String
    public let result: Result
    public let provenance: LyricsCacheProvenance
    public let savedAtMs: Int64

    public init(schemaVersion: Int, cacheKey: String, result: Result,
                provenance: LyricsCacheProvenance, savedAtMs: Int64) {
        self.schemaVersion = schemaVersion
        self.cacheKey = cacheKey
        self.result = result
        self.provenance = provenance
        self.savedAtMs = savedAtMs
    }
}

public enum CacheAdmissionDecision: String, Codable, Hashable, Sendable {
    case reject
    case immediateReturn
    case baseReapply
}

public struct CacheFreshnessInputs: Sendable {
    public let isFresh: Bool
    public let isKaraoke: Bool
    public let cacheKeyMatches: Bool
    public let schemaVersionMatches: Bool
    public let parserVersionMatches: Bool
    public let matchPolicyVersionMatches: Bool

    public init(isFresh: Bool, isKaraoke: Bool, cacheKeyMatches: Bool = true,
                schemaVersionMatches: Bool = true, parserVersionMatches: Bool = true,
                matchPolicyVersionMatches: Bool = true) {
        self.isFresh = isFresh
        self.isKaraoke = isKaraoke
        self.cacheKeyMatches = cacheKeyMatches
        self.schemaVersionMatches = schemaVersionMatches
        self.parserVersionMatches = parserVersionMatches
        self.matchPolicyVersionMatches = matchPolicyVersionMatches
    }
}

public enum CacheAdmissionPolicy {
    public static func evaluate(provenance: LyricsCacheProvenance,
                                currentPolicy: EffectiveProviderPolicy,
                                freshness: CacheFreshnessInputs) -> CacheAdmissionDecision {
        // Legal/remote denial deliberately runs before TTL checks.
        guard !currentPolicy.deniedProviders.contains(provenance.baseProvider),
              currentPolicy.orderedProviders.contains(provenance.baseProvider),
              provenance.effectiveMode == currentPolicy.effectiveMode,
              provenance.providerPolicyVersion == currentPolicy.policyVersion,
              freshness.cacheKeyMatches, freshness.schemaVersionMatches,
              freshness.parserVersionMatches, freshness.matchPolicyVersionMatches,
              freshness.isFresh else { return .reject }
        return freshness.isKaraoke ? .immediateReturn : .baseReapply
    }
}
