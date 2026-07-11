import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public struct MusixmatchProvider: LyricsProvider, Sendable {
    public let id: LyricsProviderID = .musixmatch
    private let client: MusixmatchClient

    public init(client: MusixmatchClient) { self.client = client }

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient(),
                credentialStore: any SensitiveCredentialStore) {
        let session = MusixmatchSession(credentialStore: credentialStore)
        self.client = MusixmatchClient(httpClient: httpClient, session: session)
    }

    public func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        let selected = try await selectTrack(request)
        let track = selected.track
        let candidate = selected.candidate

        do {
            let lrc = try await client.subtitle(trackID: track.trackID)
            let lines = try ProviderLRC.parse(lrc, durationMs: candidate.durationMs)
            guard lines.contains(where: { !$0.text.isEmpty }) else { throw LyricsProviderError.miss }
            return ProviderLyrics(provider: id, providerTrackID: candidate.providerTrackID,
                                  lines: lines, timing: .lineSynced, matchedCandidate: candidate)
        } catch let error as LyricsProviderError where error == .miss {
            // A missing subtitle is expected; plain lyrics are the documented fallback.
        }

        let plain = try await client.lyrics(trackID: track.trackID)
        let lines = ProviderLRC.splitPlainText(plain.text)
        guard !lines.isEmpty else { throw LyricsProviderError.miss }
        return ProviderLyrics(provider: id, providerTrackID: candidate.providerTrackID,
                              lines: lines, timing: .plain, rawCopyright: plain.copyright,
                              matchedCandidate: candidate)
    }

    private func selectTrack(_ request: LyricsProviderRequest) async throws -> (track: MusixmatchTrack, candidate: LyricsCandidate) {
        if let spotifyID = request.spotifyTrackId?.trimmingCharacters(in: .whitespacesAndNewlines), !spotifyID.isEmpty {
            do {
                let track = try await client.track(spotifyID: spotifyID)
                if let candidate = acceptedCandidate(track, request: request, direct: .spotifyTrackID) {
                    return (track, candidate)
                }
            } catch let error as LyricsProviderError where error == .miss {
                // Continue through metadata matching.
            }
        }

        do {
            let track = try await client.matcher(title: request.title, artist: request.artist, album: request.album)
            if let candidate = acceptedCandidate(track, request: request, direct: .none) {
                return (track, candidate)
            }
        } catch let error as LyricsProviderError where error == .miss {
            // Search is the final candidate source.
        }

        let tracks = try await client.search(title: request.title, artist: request.artist)
        let accepted = tracks.compactMap { track -> (MusixmatchTrack, LyricsCandidate)? in
            acceptedCandidate(track, request: request, direct: .none).map { (track, $0) }
        }.sorted {
            if $0.1.matchEvidence.totalScore != $1.1.matchEvidence.totalScore {
                return $0.1.matchEvidence.totalScore > $1.1.matchEvidence.totalScore
            }
            return $0.1.providerTrackID < $1.1.providerTrackID
        }
        guard let first = accepted.first else { throw LyricsProviderError.miss }
        return first
    }

    private func acceptedCandidate(_ track: MusixmatchTrack, request: LyricsProviderRequest,
                                   direct: DirectIdentifierEvidence) -> LyricsCandidate? {
        guard track.hasLyrics || track.hasSubtitles || track.hasRichsync else { return nil }
        let duration = track.trackLength > 0 ? track.trackLength * 1_000 : nil
        let seed = MatchEvidence(titleScore: 0, artistScore: 0, durationScore: 0,
                                 durationDeltaMs: nil, versionPenalty: 0,
                                 directIdentifier: direct, totalScore: 0,
                                 policyVersion: LyricsMatcher.policyVersion)
        let timing: Set<LyricsTiming> = track.hasSubtitles || track.hasRichsync ? [.lineSynced, .plain] : [.plain]
        var candidate = LyricsCandidate(provider: id, providerTrackID: String(track.trackID),
                                        title: track.trackName, artist: track.artistName,
                                        durationMs: duration, availableTiming: timing,
                                        matchEvidence: seed)
        let scored = LyricsMatcher.score(request: request, candidate: candidate)
        let evidence = MatchEvidence(titleScore: scored.titleScore, artistScore: scored.artistScore,
                                     durationScore: scored.durationScore, durationDeltaMs: scored.durationDeltaMs,
                                     versionPenalty: scored.versionPenalty, directIdentifier: direct,
                                     totalScore: scored.totalScore, policyVersion: scored.policyVersion)
        guard LyricsMatcher.accepts(evidence, directIdentifier: direct) else { return nil }
        candidate = LyricsCandidate(provider: id, providerTrackID: candidate.providerTrackID,
                                    title: candidate.title, artist: candidate.artist,
                                    durationMs: candidate.durationMs, availableTiming: candidate.availableTiming,
                                    matchEvidence: evidence)
        return candidate
    }
}
