import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public final class GenieClient: @unchecked Sendable {
    private static let searchURL = URL(string: "https://www.genie.co.kr/search/searchMain")!
    private static let lyricsURL = URL(string: "https://dn.genie.co.kr/app/purchase/get_msl.asp")!
    private let httpClient: ProviderHTTPClient

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient()) {
        self.httpClient = httpClient
    }

    public func search(title: String, artist: String) async throws -> [GenieTrack] {
        let query = [title, artist].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return [] }
        let response = try await httpClient.get(Self.searchURL,
            queryItems: [URLQueryItem(name: "query", value: query)])
        return try GenieSearchParser.parse(httpClient.decodeHTML(from: response))
    }

    public func fetchLyrics(trackID: String, durationMs: Int64?) async throws -> [ProviderLyricLine] {
        let response = try await httpClient.get(Self.lyricsURL, queryItems: [
            URLQueryItem(name: "path", value: "a"), URLQueryItem(name: "songid", value: trackID)
        ], headers: ["Referer": "https://www.genie.co.kr/"])
        let text = try httpClient.decodeHTML(from: response)
        return try GenieLyricsParser.parse(text, durationMs: durationMs,
                                           maxBytes: httpClient.maxResponseBytes)
    }
}
