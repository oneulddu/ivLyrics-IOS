import Foundation

public enum LyricsProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case lrclib, musixmatch, deezer, unison, bugs, genie

    public static let defaultOrder: [Self] = [.musixmatch, .deezer, .unison, .bugs, .genie, .lrclib]
}

public enum LyricsTiming: String, Codable, Hashable, Sendable {
    case plain
    case lineSynced
}

public enum LyricsProviderMode: String, Codable, Hashable, Sendable {
    case legacy
    case multiProvider

    public static func normalize(_ rawValue: String?) -> Self {
        rawValue == Self.multiProvider.rawValue ? .multiProvider : .legacy
    }
}

public enum DirectIdentifierEvidence: String, Codable, Hashable, Sendable {
    case none
    case isrc
    case spotifyTrackID
    case syncDataLrclibID
}

public struct MatchEvidence: Codable, Hashable, Sendable {
    public let titleScore: Double
    public let artistScore: Double
    public let durationScore: Double
    public let durationDeltaMs: Int64?
    public let versionPenalty: Double
    public let directIdentifier: DirectIdentifierEvidence
    public let totalScore: Double
    public let policyVersion: Int

    public init(titleScore: Double, artistScore: Double, durationScore: Double,
                durationDeltaMs: Int64?, versionPenalty: Double,
                directIdentifier: DirectIdentifierEvidence, totalScore: Double,
                policyVersion: Int) {
        self.titleScore = titleScore
        self.artistScore = artistScore
        self.durationScore = durationScore
        self.durationDeltaMs = durationDeltaMs
        self.versionPenalty = versionPenalty
        self.directIdentifier = directIdentifier
        self.totalScore = totalScore
        self.policyVersion = policyVersion
    }
}

public struct SyncDataSelectionContext: Codable, Hashable, Sendable {
    public let lrclibID: Int64
    public let lineCharCounts: [Int]
    public let sourceLineCharCounts: [Int]
    public let sourceLyricsFingerprint: String
    public let preferredLyricsSource: String
    public let shouldNormalizeParentheticalLines: Bool
    public let hasLrclibSource: Bool
    public let contextVersion: Int

    public init(lrclibID: Int64 = 0, lineCharCounts: [Int] = [], sourceLineCharCounts: [Int] = [],
                sourceLyricsFingerprint: String = "", preferredLyricsSource: String = "",
                shouldNormalizeParentheticalLines: Bool = false, hasLrclibSource: Bool = false,
                contextVersion: Int = 1) {
        self.lrclibID = lrclibID
        self.lineCharCounts = lineCharCounts
        self.sourceLineCharCounts = sourceLineCharCounts
        self.sourceLyricsFingerprint = sourceLyricsFingerprint
        self.preferredLyricsSource = preferredLyricsSource
        self.shouldNormalizeParentheticalLines = shouldNormalizeParentheticalLines
        self.hasLrclibSource = hasLrclibSource
        self.contextVersion = contextVersion
    }
}

public struct LyricsProviderRequest: Codable, Hashable, Sendable {
    public let trackKey: String
    public let title: String
    public let artist: String
    public let album: String
    public let durationMs: Int64?
    public let isrc: String?
    public let spotifyTrackId: String?
    public let locale: String
    public let syncDataSelectionContext: SyncDataSelectionContext?

    public init(trackKey: String, title: String, artist: String, album: String = "",
                durationMs: Int64? = nil, isrc: String? = nil, spotifyTrackId: String? = nil,
                locale: String = "en", syncDataSelectionContext: SyncDataSelectionContext? = nil) {
        self.trackKey = trackKey
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.isrc = isrc
        self.spotifyTrackId = spotifyTrackId
        self.locale = locale
        self.syncDataSelectionContext = syncDataSelectionContext
    }
}

public struct LyricsCandidate: Codable, Hashable, Sendable {
    public let provider: LyricsProviderID
    public let providerTrackID: String
    public let title: String
    public let artist: String
    public let album: String?
    public let durationMs: Int64?
    public let availableTiming: Set<LyricsTiming>
    public let matchEvidence: MatchEvidence

    public init(provider: LyricsProviderID, providerTrackID: String, title: String, artist: String,
                album: String? = nil, durationMs: Int64? = nil,
                availableTiming: Set<LyricsTiming> = [], matchEvidence: MatchEvidence) {
        self.provider = provider
        self.providerTrackID = providerTrackID
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.availableTiming = availableTiming
        self.matchEvidence = matchEvidence
    }
}

public struct ProviderLyricSyllable: Codable, Hashable, Sendable {
    public let text: String
    public let startMs: Int64
    public let endMs: Int64

    public init(text: String, startMs: Int64, endMs: Int64) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct ProviderSpeakerPresentation: Codable, Hashable, Sendable {
    public let speaker: String
    public let color: String?
    public let fallback: String?

    public init(speaker: String, color: String? = nil, fallback: String? = nil) {
        self.speaker = speaker
        self.color = color
        self.fallback = fallback
    }
}

public enum ProviderVocalRole: String, Codable, Hashable, Sendable {
    case lead
    case background
}

public struct ProviderVocalPart: Codable, Hashable, Sendable {
    public let id: String
    public let role: ProviderVocalRole
    public let speaker: ProviderSpeakerPresentation?
    public let text: String
    public let syllables: [ProviderLyricSyllable]

    public init(id: String, role: ProviderVocalRole,
                speaker: ProviderSpeakerPresentation? = nil, text: String,
                syllables: [ProviderLyricSyllable]) {
        self.id = id
        self.role = role
        self.speaker = speaker
        self.text = text
        self.syllables = syllables
    }
}

public struct ProviderLyricLine: Codable, Hashable, Sendable {
    public let startMs: Int64
    public let endMs: Int64?
    public let text: String
    public let syllables: [ProviderLyricSyllable]
    public let speaker: ProviderSpeakerPresentation?
    public let vocalParts: [ProviderVocalPart]

    public init(startMs: Int64, endMs: Int64? = nil, text: String,
                syllables: [ProviderLyricSyllable] = [],
                speaker: ProviderSpeakerPresentation? = nil,
                vocalParts: [ProviderVocalPart] = []) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.syllables = syllables
        self.speaker = speaker
        self.vocalParts = vocalParts
    }

    private enum CodingKeys: String, CodingKey {
        case startMs, endMs, text, syllables, speaker, vocalParts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startMs = try container.decode(Int64.self, forKey: .startMs)
        endMs = try container.decodeIfPresent(Int64.self, forKey: .endMs)
        text = try container.decode(String.self, forKey: .text)
        syllables = try container.decodeIfPresent([ProviderLyricSyllable].self, forKey: .syllables) ?? []
        speaker = try container.decodeIfPresent(ProviderSpeakerPresentation.self, forKey: .speaker)
        vocalParts = try container.decodeIfPresent([ProviderVocalPart].self, forKey: .vocalParts) ?? []
    }
}

public struct ProviderLyrics: Codable, Hashable, Sendable {
    public let provider: LyricsProviderID
    public let providerTrackID: String
    public let lines: [ProviderLyricLine]
    public let timing: LyricsTiming
    public let rawCopyright: String?
    public let matchedCandidate: LyricsCandidate
    public let fetchedAt: Date

    public init(provider: LyricsProviderID, providerTrackID: String, lines: [ProviderLyricLine],
                timing: LyricsTiming, rawCopyright: String? = nil,
                matchedCandidate: LyricsCandidate, fetchedAt: Date = Date()) {
        self.provider = provider
        self.providerTrackID = providerTrackID
        self.lines = lines
        self.timing = timing
        self.rawCopyright = rawCopyright
        self.matchedCandidate = matchedCandidate
        self.fetchedAt = fetchedAt
    }
}

public enum LyricsProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    case miss
    case authenticationRequired
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case transient
    case providerFormat
    case policyDisabled
    case cancelled

    public var description: String {
        switch self {
        case .miss: return "lyrics provider miss"
        case .authenticationRequired: return "lyrics provider authentication required"
        case .authenticationFailed: return "lyrics provider authentication failed"
        case .rateLimited: return "lyrics provider rate limited"
        case .transient: return "lyrics provider transient failure"
        case .providerFormat: return "lyrics provider response format changed"
        case .policyDisabled: return "lyrics provider disabled by policy"
        case .cancelled: return "lyrics provider request cancelled"
        }
    }
}

public protocol LyricsProvider: Sendable {
    var id: LyricsProviderID { get }
    func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics
}
