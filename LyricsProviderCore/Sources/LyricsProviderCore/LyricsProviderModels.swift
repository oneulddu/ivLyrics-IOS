import Foundation

public enum LyricsProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case lrclib, musixmatch, deezer, bugs, genie

    public static let defaultOrder: [Self] = [.musixmatch, .deezer, .bugs, .genie, .lrclib]
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

public struct ProviderLyricLine: Codable, Hashable, Sendable {
    public let startMs: Int64
    public let endMs: Int64?
    public let text: String

    public init(startMs: Int64, endMs: Int64? = nil, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
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
