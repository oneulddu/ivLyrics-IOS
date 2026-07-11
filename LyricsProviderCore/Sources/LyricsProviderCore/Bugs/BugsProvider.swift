import Foundation

public struct BugsProvider: LyricsProvider, Sendable {
    public let id: LyricsProviderID = .bugs
    private let client: BugsClient

    public init(client: BugsClient = BugsClient()) { self.client = client }

    public func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        let tracks = try await client.search(title: request.title, artist: request.artist)
        guard !tracks.isEmpty else { throw LyricsProviderError.miss }
        let scored = tracks.compactMap { track -> (BugsTrack, LyricsCandidate)? in
            let provisional = LyricsCandidate(provider: .bugs, providerTrackID: track.id,
                title: track.title, artist: track.artist, durationMs: track.durationMs,
                availableTiming: [.lineSynced, .plain], matchEvidence: emptyEvidence)
            let evidence = LyricsMatcher.score(request: request, candidate: provisional)
            guard LyricsMatcher.accepts(evidence) else { return nil }
            return (track, LyricsCandidate(provider: .bugs, providerTrackID: track.id,
                title: track.title, artist: track.artist, durationMs: track.durationMs,
                availableTiming: [.lineSynced, .plain], matchEvidence: evidence))
        }.sorted { $0.1.matchEvidence.totalScore > $1.1.matchEvidence.totalScore }
        guard let (track, candidate) = scored.first else { throw LyricsProviderError.miss }
        let lyrics = try await client.fetchLyrics(trackID: track.id, durationMs: track.durationMs)
        let lines = lyrics.synced ?? lyrics.plain ?? []
        guard !lines.isEmpty else { throw LyricsProviderError.miss }
        return ProviderLyrics(provider: .bugs, providerTrackID: track.id, lines: lines,
            timing: lyrics.synced == nil ? .plain : .lineSynced, matchedCandidate: candidate)
    }

    private var emptyEvidence: MatchEvidence {
        MatchEvidence(titleScore: 0, artistScore: 0, durationScore: 0,
                      durationDeltaMs: nil, versionPenalty: 0, directIdentifier: .none,
                      totalScore: 0, policyVersion: LyricsMatcher.policyVersion)
    }
}
