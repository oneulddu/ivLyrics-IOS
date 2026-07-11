import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public struct DeezerProvider: LyricsProvider, Sendable {
    public let id: LyricsProviderID = .deezer
    private let client: DeezerClient
    private let authSession: DeezerAuthSession

    public init(client: DeezerClient, authSession: DeezerAuthSession) {
        self.client = client
        self.authSession = authSession
    }

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient(),
                credentialStore: any SensitiveCredentialStore) {
        let auth = DeezerAuthSession(credentialStore: credentialStore)
        self.authSession = auth
        self.client = DeezerClient(httpClient: httpClient, authSession: auth)
    }

    public func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        let arl = try await authSession.requireARL()
        let tracks = try await client.search(title: request.title, artist: request.artist)
        let candidates = tracks.compactMap { track -> (DeezerTrack, LyricsCandidate)? in
            let durationMs = track.duration > 0 ? track.duration * 1_000 : nil
            let seed = MatchEvidence(titleScore: 0, artistScore: 0, durationScore: 0,
                                     durationDeltaMs: nil, versionPenalty: 0,
                                     directIdentifier: .none, totalScore: 0,
                                     policyVersion: LyricsMatcher.policyVersion)
            var candidate = LyricsCandidate(provider: id, providerTrackID: String(track.id),
                                            title: track.title, artist: track.artist.name,
                                            durationMs: durationMs,
                                            availableTiming: [.lineSynced, .plain], matchEvidence: seed)
            let evidence = LyricsMatcher.score(request: request, candidate: candidate)
            guard LyricsMatcher.accepts(evidence) else { return nil }
            candidate = LyricsCandidate(provider: id, providerTrackID: candidate.providerTrackID,
                                        title: candidate.title, artist: candidate.artist,
                                        durationMs: candidate.durationMs,
                                        availableTiming: candidate.availableTiming,
                                        matchEvidence: evidence)
            return (track, candidate)
        }.sorted {
            if $0.1.matchEvidence.totalScore != $1.1.matchEvidence.totalScore {
                return $0.1.matchEvidence.totalScore > $1.1.matchEvidence.totalScore
            }
            return $0.1.providerTrackID < $1.1.providerTrackID
        }
        guard let selected = candidates.first else { throw LyricsProviderError.miss }
        let payload = try await client.lyrics(trackID: selected.0.id, arl: arl)
        return try makeResult(payload, candidate: selected.1)
    }

    private func makeResult(_ payload: DeezerLyrics, candidate: LyricsCandidate) throws -> ProviderLyrics {
        if let synchronized = payload.synchronizedLines {
            let pairs = synchronized.compactMap { line -> (Int64, String)? in
                let text = line.line.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : (line.milliseconds, text)
            }
            if !pairs.isEmpty {
                let lines = try ProviderLRC.buildLines(from: pairs, durationMs: candidate.durationMs)
                return ProviderLyrics(provider: id, providerTrackID: candidate.providerTrackID,
                                      lines: lines, timing: .lineSynced,
                                      rawCopyright: normalized(payload.copyright),
                                      matchedCandidate: candidate)
            }
        }
        if let wordLines = payload.synchronizedWordByWordLines {
            let pairs = wordLines.compactMap { line -> (Int64, String)? in
                guard let first = line.words.first else { return nil }
                let text = line.words.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                return text.isEmpty ? nil : (first.start, text)
            }
            if !pairs.isEmpty {
                let lines = try ProviderLRC.buildLines(from: pairs, durationMs: candidate.durationMs)
                return ProviderLyrics(provider: id, providerTrackID: candidate.providerTrackID,
                                      lines: lines, timing: .lineSynced,
                                      rawCopyright: normalized(payload.copyright),
                                      matchedCandidate: candidate)
            }
        }
        let lines = ProviderLRC.splitPlainText(payload.text ?? "")
        guard !lines.isEmpty else { throw LyricsProviderError.miss }
        return ProviderLyrics(provider: id, providerTrackID: candidate.providerTrackID,
                              lines: lines, timing: .plain,
                              rawCopyright: normalized(payload.copyright),
                              matchedCandidate: candidate)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
