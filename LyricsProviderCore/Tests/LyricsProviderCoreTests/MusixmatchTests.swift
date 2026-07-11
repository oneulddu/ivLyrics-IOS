import Foundation
import XCTest
@testable import LyricsProviderCore

final class MusixmatchTests: XCTestCase {
    override func tearDown() { MXMURLProtocol.handler = nil; super.tearDown() }

    func testSigningFixedVectorAndDateChangesSignature() throws {
        let url = "https://apic.musixmatch.com/ws/1.1/track.get?app_id=android-player-v1.0&format=json&track_id=42&usertoken=test-token"
        let first = MusixmatchSigning.sign(urlString: url, date: date(2024, 1, 2))
        XCTAssertEqual(first[0], URLQueryItem(name: "signature", value: "oFJgbjsfNfZIDkIo/riT2gPakfM=\n"))
        XCTAssertEqual(first[1], URLQueryItem(name: "signature_protocol", value: "sha1"))
        XCTAssertNotEqual(first[0].value, MusixmatchSigning.sign(urlString: url, date: date(2024, 1, 3))[0].value)
    }

    func testTokenParseAndLRCPreferredOverPlain() async throws {
        let calls = MXMLocked<[String]>([])
        MXMURLProtocol.handler = { request in
            calls.mutate { $0.append(request.url!.path) }
            switch request.url!.lastPathComponent {
            case "token.get": return Self.response(request, Self.envelope(#"{"user_token":"synthetic-token"}"#))
            case "matcher.track.get": return Self.response(request, Self.trackEnvelope())
            case "track.subtitle.get": return Self.response(request, Self.envelope(#"{"subtitle":{"subtitle_body":"[00:01.00]One\n[00:02.00]Two"}}"#))
            default: return Self.response(request, Self.envelope("{}", status: 404))
            }
        }
        let result = try await provider().fetch(request())
        XCTAssertEqual(result.timing, .lineSynced)
        XCTAssertEqual(result.lines.map(\.text), ["One", "Two"])
        XCTAssertFalse(calls.value.contains(where: { $0.hasSuffix("track.lyrics.get") }))
    }

    func testPlainFallbackWhenSubtitleMissing() async throws {
        MXMURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "token.get": return Self.response(request, Self.envelope(#"{"user_token":"token-a"}"#))
            case "matcher.track.get": return Self.response(request, Self.trackEnvelope())
            case "track.subtitle.get": return Self.response(request, Self.envelope("{}", status: 404))
            case "track.lyrics.get": return Self.response(request, Self.envelope(#"{"lyrics":{"lyrics_body":"Tiny one\nTiny two","lyrics_copyright":"Synthetic"}}"#))
            default: fatalError()
            }
        }
        let result = try await provider().fetch(request())
        XCTAssertEqual(result.timing, .plain)
        XCTAssertEqual(result.lines.map(\.text), ["Tiny one", "Tiny two"])
    }

    func testRenewHintRefreshesExactlyOnceAndRetriesOriginalRequest() async throws {
        let tokenCalls = MXMLocked(0), matcherCalls = MXMLocked(0)
        MXMURLProtocol.handler = { request in
            if request.url!.lastPathComponent == "token.get" {
                tokenCalls.mutate { $0 += 1 }
                return Self.response(request, Self.envelope(#"{"user_token":"token-\#(tokenCalls.value)"}"#))
            }
            if request.url!.lastPathComponent == "matcher.track.get" {
                matcherCalls.mutate { $0 += 1 }
                return Self.response(request, matcherCalls.value == 1 ? Self.envelope("{}", status: 401, hint: "renew") : Self.trackEnvelope())
            }
            if request.url!.lastPathComponent == "track.subtitle.get" {
                return Self.response(request, Self.envelope(#"{"subtitle":{"subtitle_body":"[00:01.00]One\n[00:02.00]Two"}}"#))
            }
            fatalError()
        }
        _ = try await provider().fetch(request())
        XCTAssertEqual(tokenCalls.value, 2)
        XCTAssertEqual(matcherCalls.value, 2)
    }

    func testSecondRenewFailsWithoutThirdTokenIssue() async {
        let tokenCalls = MXMLocked(0)
        MXMURLProtocol.handler = { request in
            if request.url!.lastPathComponent == "token.get" {
                tokenCalls.mutate { $0 += 1 }
                return Self.response(request, Self.envelope(#"{"user_token":"safe-token"}"#))
            }
            return Self.response(request, Self.envelope("{}", status: 401, hint: "renew"))
        }
        await assertError(.authenticationFailed) { _ = try await self.provider().fetch(self.request()) }
        XCTAssertEqual(tokenCalls.value, 2)
    }

    func testCaptchaMapsToRateLimited() async {
        MXMURLProtocol.handler = { request in
            request.url!.lastPathComponent == "token.get"
                ? Self.response(request, Self.envelope(#"{"user_token":"safe-token"}"#))
                : Self.response(request, Self.envelope("{}", status: 401, hint: "captcha"))
        }
        await assertError(.rateLimited(retryAfter: nil)) { _ = try await self.provider().fetch(self.request()) }
    }

    func testTruncatedJSONIsProviderFormatAndDoesNotExposeToken() async {
        MXMURLProtocol.handler = { request in
            request.url!.lastPathComponent == "token.get"
                ? Self.response(request, Self.envelope(#"{"user_token":"never-expose-me"}"#))
                : Self.response(request, "{\"message\":")
        }
        do { _ = try await provider().fetch(request()); XCTFail() }
        catch {
            XCTAssertEqual(error as? LyricsProviderError, .providerFormat)
            XCTAssertFalse(String(describing: error).contains("never-expose-me"))
        }
    }

    func testConcurrentFetchesUseSingleTokenRequest() async throws {
        let tokenCalls = MXMLocked(0)
        MXMURLProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "token.get":
                tokenCalls.mutate { $0 += 1 }; Thread.sleep(forTimeInterval: 0.05)
                return Self.response(request, Self.envelope(#"{"user_token":"shared-token"}"#))
            case "matcher.track.get": return Self.response(request, Self.trackEnvelope())
            case "track.subtitle.get": return Self.response(request, Self.envelope(#"{"subtitle":{"subtitle_body":"[00:01.00]One\n[00:02.00]Two"}}"#))
            default: fatalError()
            }
        }
        let provider = provider()
        try await withThrowingTaskGroup(of: ProviderLyrics.self) { group in
            for _ in 0..<8 { group.addTask { try await provider.fetch(self.request()) } }
            for try await _ in group {}
        }
        XCTAssertEqual(tokenCalls.value, 1)
    }

    private func provider() -> MusixmatchProvider {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MXMURLProtocol.self]
        let client = ProviderHTTPClient(configuration: config)
        return MusixmatchProvider(client: MusixmatchClient(httpClient: client,
            session: MusixmatchSession(credentialStore: InMemoryCredentialStore()), now: { self.date(2024, 1, 2) }))
    }
    private func request() -> LyricsProviderRequest { .init(trackKey: "k", title: "Signal", artist: "Alpha", album: "Album", durationMs: 180_000) }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date { Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: year, month: month, day: day))! }
    private func assertError(_ expected: LyricsProviderError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("expected \(expected)") } catch { XCTAssertEqual(error as? LyricsProviderError, expected) }
    }
    private static func trackEnvelope() -> String { envelope(#"{"track":{"track_id":42,"track_name":"Signal","track_length":180,"artist_name":"Alpha","has_lyrics":1,"has_subtitles":1,"has_richsync":0}}"#) }
    private static func envelope(_ body: String, status: Int = 200, hint: String = "") -> String {
        #"{"message":{"header":{"status_code":\#(status),"hint":"\#(hint)"},"body":\#(body)}}"#
    }
    private static func response(_ request: URLRequest, _ text: String) -> (HTTPURLResponse, Data) { (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, Data(text.utf8)) }
}

private final class MXMURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var stored: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { do { let (response,data) = try Self.handler!(request); client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) } catch { client?.urlProtocol(self,didFailWithError:error) } }
    override func stopLoading() {}
}
private final class MXMLocked<Value>: @unchecked Sendable { private let lock = NSLock(); private var storage: Value; init(_ value: Value) { storage = value }; var value: Value { lock.lock(); defer { lock.unlock() }; return storage }; func mutate(_ body: (inout Value)->Void) { lock.lock(); body(&storage); lock.unlock() } }
