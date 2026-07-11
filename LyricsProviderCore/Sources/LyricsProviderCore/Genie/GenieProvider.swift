import Foundation

public struct GenieProvider: LyricsProvider, Sendable {
    public let id: LyricsProviderID = .genie
    private let client: GenieClient

    public init(client: GenieClient = GenieClient()) { self.client = client }

    public func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        let tracks = try await client.search(title: request.title, artist: request.artist)
        guard !tracks.isEmpty else { throw LyricsProviderError.miss }
        let scored = tracks.compactMap { track -> (GenieTrack, LyricsCandidate)? in
            let provisional = LyricsCandidate(provider: .genie, providerTrackID: track.id,
                title: track.title, artist: track.artist, durationMs: track.durationMs,
                availableTiming: [.lineSynced], matchEvidence: emptyEvidence)
            let evidence = LyricsMatcher.score(request: request, candidate: provisional)
            guard LyricsMatcher.accepts(evidence) else { return nil }
            return (track, LyricsCandidate(provider: .genie, providerTrackID: track.id,
                title: track.title, artist: track.artist, durationMs: track.durationMs,
                availableTiming: [.lineSynced], matchEvidence: evidence))
        }.sorted { $0.1.matchEvidence.totalScore > $1.1.matchEvidence.totalScore }
        guard let (track, candidate) = scored.first else { throw LyricsProviderError.miss }
        let lines = try await client.fetchLyrics(trackID: track.id, durationMs: track.durationMs)
        guard !lines.isEmpty else { throw LyricsProviderError.miss }
        return ProviderLyrics(provider: .genie, providerTrackID: track.id, lines: lines,
            timing: .lineSynced, matchedCandidate: candidate)
    }

    private var emptyEvidence: MatchEvidence {
        MatchEvidence(titleScore: 0, artistScore: 0, durationScore: 0,
                      durationDeltaMs: nil, versionPenalty: 0, directIdentifier: .none,
                      totalScore: 0, policyVersion: LyricsMatcher.policyVersion)
    }
}
