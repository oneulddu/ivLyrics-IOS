import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public final class BugsClient: @unchecked Sendable {
    private static let searchURL = URL(string: "https://m.bugs.co.kr/api/getSearchList")!
    private static let syncedBaseURL = URL(string: "https://music.bugs.co.kr/player/lyrics/T")!
    private static let plainBaseURL = URL(string: "https://music.bugs.co.kr/player/lyrics/N")!
    private let httpClient: ProviderHTTPClient

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient()) {
        self.httpClient = httpClient
    }

    public func search(title: String, artist: String) async throws -> [BugsTrack] {
        let query = [title, artist].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return [] }
        let response = try await httpClient.get(Self.searchURL, queryItems: [
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "size", value: "30")
        ])
        return try BugsParser.parseSearch(response.data)
    }

    public func fetchLyrics(trackID: String, durationMs: Int64?) async throws
        -> (synced: [ProviderLyricLine]?, plain: [ProviderLyricLine]?) {
        // Keep the global HTTP concurrency budget honest: a Bugs provider task
        // must not fan out into two simultaneous requests behind the semaphore.
        let synced = await outcome { try await fetchSynced(trackID: trackID, durationMs: durationMs) }
        if let lines = try? synced.get() { return (lines, nil) }
        let plain = await outcome { try await fetchPlain(trackID: trackID) }
        if let lines = try? plain.get() { return (nil, lines) }
        throw preferredError(synced, plain)
    }

    private func fetchSynced(trackID: String, durationMs: Int64?) async throws -> [ProviderLyricLine] {
        let response = try await httpClient.get(Self.syncedBaseURL.appendingPathComponent(trackID))
        return try BugsParser.parseSyncedLyrics(BugsParser.parseLyricsBody(response.data), durationMs: durationMs)
    }

    private func fetchPlain(trackID: String) async throws -> [ProviderLyricLine] {
        let response = try await httpClient.get(Self.plainBaseURL.appendingPathComponent(trackID))
        let text = try BugsParser.normalizePlainLyrics(BugsParser.parseLyricsBody(response.data))
        let lines = ProviderLRC.splitPlainText(text)
        guard !lines.isEmpty else { throw LyricsProviderError.miss }
        return lines
    }

    private func preferredError<T, U>(_ first: Result<T, Error>, _ second: Result<U, Error>) -> Error {
        let errors = [first.failure, second.failure].compactMap { $0 }
        if errors.contains(where: { if case .rateLimited = $0 as? LyricsProviderError { return true }; return false }) {
            return errors.first { if case .rateLimited = $0 as? LyricsProviderError { return true }; return false }!
        }
        for expected in [LyricsProviderError.transient, .providerFormat, .miss] {
            if errors.contains(where: { ($0 as? LyricsProviderError) == expected }) { return expected }
        }
        return errors.first ?? LyricsProviderError.miss
    }

    private func outcome<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
