import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public final class MusixmatchClient: @unchecked Sendable {
    private static let baseURL = URL(string: "https://apic.musixmatch.com/ws/1.1/")!
    private static let appID = "android-player-v1.0"
    private static let headers = [
        "Cookie": "AWSELBCORS=0; AWSELB=0",
        "User-Agent": "Dalvik/2.1.0 (Linux; U; Android 13; Pixel 6 Build/T3B2.230316.003)",
    ]

    private enum ClientError: Error { case tokenExpired }
    private struct HeaderEnvelope: Decodable { let message: Message; struct Message: Decodable { let header: Header }; struct Header: Decodable { let statusCode: Int; let hint: String?; enum CodingKeys: String, CodingKey { case statusCode = "status_code"; case hint } } }
    private struct BodyEnvelope<Body: Decodable>: Decodable { let message: Message; struct Message: Decodable { let body: Body } }

    private let httpClient: ProviderHTTPClient
    private let session: MusixmatchSession
    private let now: @Sendable () -> Date

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient(),
                session: MusixmatchSession,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.httpClient = httpClient
        self.session = session
        self.now = now
    }

    func track(spotifyID: String) async throws -> MusixmatchTrack {
        try await request("track.get", queryItems: [.init(name: "track_spotify_id", value: spotifyID)], as: MusixmatchTrackBody.self).track
    }

    func matcher(title: String, artist: String, album: String) async throws -> MusixmatchTrack {
        var items = [URLQueryItem(name: "q_track", value: title), .init(name: "q_artist", value: artist)]
        if !album.isEmpty { items.append(.init(name: "q_album", value: album)) }
        return try await request("matcher.track.get", queryItems: items, as: MusixmatchTrackBody.self).track
    }

    func search(title: String, artist: String, pageSize: Int = 10, page: Int = 1) async throws -> [MusixmatchTrack] {
        let body = try await request("track.search", queryItems: [
            .init(name: "q_track", value: title), .init(name: "q_artist", value: artist),
            .init(name: "f_has_lyrics", value: "1"), .init(name: "s_track_rating", value: "desc"),
            .init(name: "page_size", value: String(pageSize)), .init(name: "page", value: String(page)),
        ], as: MusixmatchTrackListBody.self)
        return body.trackList.map(\.track)
    }

    func subtitle(trackID: Int64) async throws -> String {
        try await request("track.subtitle.get", queryItems: [
            .init(name: "track_id", value: String(trackID)), .init(name: "subtitle_format", value: "lrc"),
        ], as: MusixmatchSubtitleBody.self).subtitle.subtitleBody
    }

    func lyrics(trackID: Int64) async throws -> (text: String, copyright: String?) {
        let value = try await request("track.lyrics.get", queryItems: [.init(name: "track_id", value: String(trackID))], as: MusixmatchLyricsBody.self).lyrics
        return (value.lyricsBody, value.lyricsCopyright?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
    }

    private func request<Body: Decodable>(_ endpoint: String, queryItems: [URLQueryItem], as type: Body.Type) async throws -> Body {
        let unsigned = try makeURL(endpoint: endpoint, queryItems: queryItems)
        let token = try await session.token { [weak self] in
            guard let self else { throw LyricsProviderError.transient }
            return try await self.issueToken()
        }
        do {
            return try await authenticated(unsignedURL: unsigned, token: token, as: type)
        } catch ClientError.tokenExpired {
            let renewed = try await session.renew(replacing: token) { [weak self] in
                guard let self else { throw LyricsProviderError.transient }
                return try await self.issueToken()
            }
            do {
                return try await authenticated(unsignedURL: unsigned, token: renewed, as: type)
            } catch ClientError.tokenExpired {
                throw LyricsProviderError.authenticationFailed
            }
        }
    }

    private func authenticated<Body: Decodable>(unsignedURL: URL, token: String, as type: Body.Type) async throws -> Body {
        guard var components = URLComponents(url: unsignedURL, resolvingAgainstBaseURL: false) else { throw LyricsProviderError.providerFormat }
        components.queryItems = (components.queryItems ?? []) + [.init(name: "usertoken", value: token)]
        guard let tokenURL = components.url else { throw LyricsProviderError.providerFormat }
        let finalURL = try signedURL(tokenURL)
        let response = try await httpClient.get(finalURL, headers: Self.headers)
        return try parse(response.data, as: type)
    }

    private func issueToken() async throws -> String {
        let timestamp = ISO8601DateFormatter().string(from: now())
        let guid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        let items: [URLQueryItem] = [
            .init(name: "adv_id", value: UUID().uuidString.lowercased()), .init(name: "root", value: "0"),
            .init(name: "sideloaded", value: "0"), .init(name: "build_number", value: "2022090901"),
            .init(name: "guid", value: guid), .init(name: "lang", value: "en_US"),
            .init(name: "model", value: "manufacturer/Google brand/Google model/Pixel 6"),
            .init(name: "timestamp", value: timestamp),
        ]
        let url = try signedURL(makeURL(endpoint: "token.get", queryItems: items))
        let response = try await httpClient.get(url, headers: Self.headers)
        let token = try parse(response.data, as: MusixmatchTokenBody.self).userToken
        guard !token.isEmpty else { throw LyricsProviderError.providerFormat }
        return token
    }

    private func makeURL(endpoint: String, queryItems: [URLQueryItem]) throws -> URL {
        let url = Self.baseURL.appendingPathComponent(endpoint)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw LyricsProviderError.providerFormat }
        components.queryItems = [
            .init(name: "app_id", value: Self.appID), .init(name: "format", value: "json"),
        ] + queryItems
        guard let result = components.url else { throw LyricsProviderError.providerFormat }
        return result
    }

    private func signedURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw LyricsProviderError.providerFormat }
        components.queryItems = (components.queryItems ?? []) + MusixmatchSigning.sign(urlString: url.absoluteString, date: now())
        guard let result = components.url else { throw LyricsProviderError.providerFormat }
        return result
    }

    private func parse<Body: Decodable>(_ data: Data, as type: Body.Type) throws -> Body {
        let decoder = JSONDecoder()
        let header: HeaderEnvelope
        do { header = try decoder.decode(HeaderEnvelope.self, from: data) }
        catch { throw LyricsProviderError.providerFormat }
        let status = header.message.header.statusCode
        let hint = header.message.header.hint?.lowercased() ?? ""
        if status < 400 {
            do { return try decoder.decode(BodyEnvelope<Body>.self, from: data).message.body }
            catch { throw LyricsProviderError.providerFormat }
        }
        if status == 404 { throw LyricsProviderError.miss }
        if status == 401 && hint == "renew" { throw ClientError.tokenExpired }
        if status == 401 && hint == "captcha" { throw LyricsProviderError.rateLimited(retryAfter: nil) }
        if status == 429 { throw LyricsProviderError.rateLimited(retryAfter: nil) }
        if status >= 500 { throw LyricsProviderError.transient }
        if status == 401 || status == 403 { throw LyricsProviderError.authenticationFailed }
        throw LyricsProviderError.providerFormat
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
