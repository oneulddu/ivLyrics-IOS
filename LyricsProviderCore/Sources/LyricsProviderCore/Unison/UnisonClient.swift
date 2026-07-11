import Foundation

public final class UnisonClient: @unchecked Sendable {
    private static let endpoint = URL(string: "https://unison.boidu.dev/lyrics")!
    private let httpClient: ProviderHTTPClient

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient(maxResponseBytes: 750_000)) {
        self.httpClient = httpClient
    }

    func response(for request: LyricsProviderRequest) async throws -> (UnisonLyricsData, MatchEvidence) {
        let attempts = requestAttempts(request)
        guard !attempts.isEmpty else { throw LyricsProviderError.miss }
        var sawMalformed = false
        for attempt in attempts {
            try Task.checkCancellation()
            do {
                let response = try await httpClient.get(Self.endpoint, queryItems: attempt.queryItems,
                    headers: ["Accept": "application/json", "User-Agent": "ivLyrics-iOS"],
                    timeout: 10)
                let envelope: UnisonResponseEnvelope
                do {
                    envelope = try httpClient.decodeJSON(UnisonResponseEnvelope.self, from: response)
                } catch {
                    sawMalformed = true
                    continue
                }
                guard envelope.success, let data = envelope.data,
                      !data.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !data.format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    sawMalformed = true
                    continue
                }
                if attempt.requiresExactMetadata && !exactMetadata(data, request: request) { continue }
                let provisional = LyricsCandidate(provider: .unison, providerTrackID: "unison",
                    title: data.song, artist: data.artist, album: data.album,
                    durationMs: data.durationMs, availableTiming: [],
                    matchEvidence: MatchEvidence(titleScore: 0, artistScore: 0, durationScore: 0,
                        durationDeltaMs: nil, versionPenalty: 0, directIdentifier: .none,
                        totalScore: 0, policyVersion: LyricsMatcher.policyVersion))
                let evidence = LyricsMatcher.score(request: request, candidate: provisional)
                guard LyricsMatcher.accepts(evidence) else { continue }
                return (data, evidence)
            } catch LyricsProviderError.miss {
                continue
            }
        }
        if sawMalformed { throw LyricsProviderError.providerFormat }
        throw LyricsProviderError.miss
    }

    private struct Attempt {
        let queryItems: [URLQueryItem]
        let requiresExactMetadata: Bool
    }

    private func requestAttempts(_ request: LyricsProviderRequest) -> [Attempt] {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artists = artistCandidates(request.artist)
        guard !title.isEmpty, !artists.isEmpty else { return [] }
        let album = request.album.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAlbum = !album.isEmpty && album.lowercased() != "undefined"
        var attempts: [Attempt] = []
        for includeAlbum in hasAlbum ? [true, false] : [false] {
            for artist in artists {
                attempts.append(Attempt(queryItems: query(title: title, artist: artist,
                    album: includeAlbum ? album : nil, durationMs: request.durationMs),
                    requiresExactMetadata: false))
            }
        }
        if request.durationMs.map({ $0 > 0 }) == true {
            for artist in artists {
                attempts.append(Attempt(queryItems: query(title: title, artist: artist,
                    album: nil, durationMs: nil), requiresExactMetadata: true))
            }
        }
        var seen = Set<String>()
        return attempts.filter { attempt in
            let key = attempt.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
            return seen.insert(key).inserted
        }
    }

    private func query(title: String, artist: String, album: String?, durationMs: Int64?) -> [URLQueryItem] {
        var result = [URLQueryItem(name: "song", value: title), URLQueryItem(name: "artist", value: artist)]
        if let durationMs, durationMs > 0 {
            result.append(URLQueryItem(name: "duration", value: String(Int((Double(durationMs) / 1_000).rounded()))))
        }
        if let album { result.append(URLQueryItem(name: "album", value: album)) }
        return result
    }

    private func artistCandidates(_ value: String) -> [String] {
        let artist = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return [] }
        guard let separator = artist.range(of: #"\s*(?:,|;|\bfeat\.?\b|\bfeaturing\b|\s&\s)\s*"#,
                                           options: [.regularExpression, .caseInsensitive]) else { return [artist] }
        let primary = String(artist[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return primary.isEmpty || LyricsMatcher.normalize(primary) == LyricsMatcher.normalize(artist)
            ? [artist] : [artist, primary]
    }

    private func exactMetadata(_ data: UnisonLyricsData, request: LyricsProviderRequest) -> Bool {
        LyricsMatcher.normalize(data.song) == LyricsMatcher.normalize(request.title)
            && artistCandidates(request.artist).contains {
                LyricsMatcher.normalize($0) == LyricsMatcher.normalize(data.artist)
            }
    }
}
