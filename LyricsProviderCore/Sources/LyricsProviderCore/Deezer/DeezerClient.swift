import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public final class DeezerClient: @unchecked Sendable {
    private static let searchURL = URL(string: "https://api.deezer.com/search")!
    private static let authURL = URL(string: "https://auth.deezer.com/login/arl?jo=p&rto=c&i=c")!
    private static let graphQLURL = URL(string: "https://pipe.deezer.com/api")!
    private static let lyricsQuery = """
    query GetLyrics($trackId: String!) { track(trackId: $trackId) { id lyrics { id text copyright synchronizedLines { lrcTimestamp line milliseconds duration } synchronizedWordByWordLines { start end words { start end word } } } } }
    """

    private enum ClientError: Error { case authentication }
    private let httpClient: ProviderHTTPClient
    private let authSession: DeezerAuthSession

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient(), authSession: DeezerAuthSession) {
        self.httpClient = httpClient
        self.authSession = authSession
    }

    public func validateAuthentication(arl: String) async throws {
        _ = try await authSession.token(for: arl) { [weak self] in
            guard let self else { throw LyricsProviderError.authenticationFailed }
            return try await self.exchangeJWT(arl: arl)
        }
    }

    func search(title: String, artist: String) async throws -> [DeezerTrack] {
        let cleanTitle = title.replacingOccurrences(of: "\"", with: "")
        let cleanArtist = artist.replacingOccurrences(of: "\"", with: "")
        let query = "track:\"\(cleanTitle)\" artist:\"\(cleanArtist)\""
        let response = try await httpClient.get(Self.searchURL, queryItems: [.init(name: "q", value: query)])
        return try httpClient.decodeJSON(DeezerSearchResponse.self, from: response).data
    }

    func lyrics(trackID: Int64, arl: String) async throws -> DeezerLyrics {
        let token = try await authSession.token(for: arl) { [weak self] in
            guard let self else { throw LyricsProviderError.authenticationFailed }
            return try await self.exchangeJWT(arl: arl)
        }
        do {
            return try await queryLyrics(trackID: trackID, jwt: token)
        } catch ClientError.authentication {
            let refreshed = try await authSession.refresh(replacing: token, arl: arl) { [weak self] in
                guard let self else { throw LyricsProviderError.authenticationFailed }
                return try await self.exchangeJWT(arl: arl)
            }
            do {
                return try await queryLyrics(trackID: trackID, jwt: refreshed)
            } catch ClientError.authentication {
                throw LyricsProviderError.authenticationFailed
            }
        }
    }

    private func exchangeJWT(arl: String) async throws -> String {
        let response: ProviderHTTPClient.Response
        do {
            response = try await httpClient.post(Self.authURL, body: Data(), headers: [
                "Cookie": "arl=\(arl)", "Content-Length": "0",
            ], allowedStatus: 200..<600)
        } catch let error as LyricsProviderError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LyricsProviderError.transient }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw LyricsProviderError.authenticationFailed
        }
        if response.statusCode == 429 { throw LyricsProviderError.rateLimited(retryAfter: nil) }
        if response.statusCode >= 500 { throw LyricsProviderError.transient }
        guard (200..<300).contains(response.statusCode) else {
            throw LyricsProviderError.providerFormat
        }
        let payload: DeezerAuthResponse
        do { payload = try httpClient.decodeJSON(DeezerAuthResponse.self, from: response) }
        catch { throw LyricsProviderError.providerFormat }
        guard let jwt = payload.jwt?.trimmingCharacters(in: .whitespacesAndNewlines), !jwt.isEmpty else {
            throw LyricsProviderError.authenticationFailed
        }
        return jwt
    }

    private func queryLyrics(trackID: Int64, jwt: String) async throws -> DeezerLyrics {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "query": Self.lyricsQuery,
                "variables": ["trackId": String(trackID)],
            ])
        } catch { throw LyricsProviderError.providerFormat }

        let response: ProviderHTTPClient.Response
        do {
            response = try await httpClient.post(Self.graphQLURL, body: body, headers: [
                "Authorization": "Bearer \(jwt)", "Content-Type": "application/json",
            ], allowedStatus: 200..<500)
        } catch { throw error }
        if response.statusCode == 401 || response.statusCode == 403 { throw ClientError.authentication }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 429 { throw LyricsProviderError.rateLimited(retryAfter: nil) }
            throw LyricsProviderError.providerFormat
        }
        let payload = try httpClient.decodeJSON(DeezerGraphQLResponse.self, from: response)
        if let errors = payload.errors, !errors.isEmpty {
            let messages = errors.map { $0.message.lowercased() }
            if messages.contains(where: { value in
                ["unauthorized", "forbidden", "unauthenticated", "token expired", "authentication"].contains(where: value.contains)
            }) { throw ClientError.authentication }
            if messages.contains(where: { $0.contains("not found") || $0.contains("not available") }) {
                throw LyricsProviderError.miss
            }
            throw LyricsProviderError.providerFormat
        }
        guard let lyrics = payload.data?.track?.lyrics else { throw LyricsProviderError.miss }
        return lyrics
    }
}
