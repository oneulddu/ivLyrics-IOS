import CryptoKit
import Foundation

public struct UnisonProvider: LyricsProvider, Sendable {
    public let id: LyricsProviderID = .unison
    private let client: UnisonClient

    public init(client: UnisonClient = UnisonClient()) { self.client = client }

    public func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        let (data, evidence) = try await client.response(for: request)
        try Task.checkCancellation()
        let parsed = try UnisonParser.parse(data, durationMs: request.durationMs)
        let trackID = deterministicTrackID(data)
        let candidate = LyricsCandidate(provider: .unison, providerTrackID: trackID,
            title: data.song, artist: data.artist, album: data.album, durationMs: data.durationMs,
            availableTiming: [parsed.timing], matchEvidence: evidence)
        return ProviderLyrics(provider: .unison, providerTrackID: trackID, lines: parsed.lines,
            timing: parsed.timing, rawCopyright: "Lyrics from Unison (https://unison.boidu.dev).",
            matchedCandidate: candidate)
    }

    private func deterministicTrackID(_ data: UnisonLyricsData) -> String {
        let key = [data.song, data.artist, data.album ?? "", data.durationMs.map(String.init) ?? ""]
            .map(LyricsMatcher.normalize).joined(separator: "|")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "unison-\(digest)"
    }
}
