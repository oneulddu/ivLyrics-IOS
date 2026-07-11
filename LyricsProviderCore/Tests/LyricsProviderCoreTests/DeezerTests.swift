import Foundation
import XCTest
@testable import LyricsProviderCore

final class DeezerTests: XCTestCase {
    override func tearDown() { DeezerURLProtocol.handler = nil; super.tearDown() }

    func testUnconfiguredRequiresAuthenticationWithoutNetwork() async {
        let calls = DeezerLocked(0)
        DeezerURLProtocol.handler = { request in calls.mutate { $0 += 1 }; fatalError("network must not run") }
        await assertError(.authenticationRequired) { _ = try await self.provider(store: InMemoryCredentialStore()).fetch(self.request()) }
        XCTAssertEqual(calls.value, 0)
    }

    func testAuthSearchAndSynchronizedLinesHappyPath() async throws {
        DeezerURLProtocol.handler = happyHandler(lyrics: #"{"text":"Fallback","copyright":"Synthetic","synchronizedLines":[{"lrcTimestamp":"[00:01.00]","line":"One","milliseconds":1000,"duration":900},{"lrcTimestamp":"[00:02.00]","line":"Two","milliseconds":2000,"duration":900}],"synchronizedWordByWordLines":null}"#)
        let result = try await configuredProvider().fetch(request())
        XCTAssertEqual(result.timing, .lineSynced)
        XCTAssertEqual(result.lines.map(\.startMs), [1000, 2000])
        XCTAssertEqual(result.lines.map(\.text), ["One", "Two"])
    }

    func testWordByWordCollapsesUsingFirstWordStartAndOrdering() async throws {
        let lyrics = #"{"text":"Fallback","synchronizedLines":[],"synchronizedWordByWordLines":[{"start":900,"end":1900,"words":[{"start":1100,"end":1300,"word":"Small"},{"start":1350,"end":1600,"word":"signal"}]},{"start":2000,"end":2900,"words":[{"start":2100,"end":2300,"word":"Moves"},{"start":2350,"end":2500,"word":"on"}]}]}"#
        DeezerURLProtocol.handler = happyHandler(lyrics: lyrics)
        let result = try await configuredProvider().fetch(request())
        XCTAssertEqual(result.timing, .lineSynced)
        XCTAssertEqual(result.lines.map(\.startMs), [1100, 2100])
        XCTAssertEqual(result.lines.map(\.text), ["Small signal", "Moves on"])
    }

    func testPlainOnlyFallback() async throws {
        DeezerURLProtocol.handler = happyHandler(lyrics: #"{"text":"Tiny one\nTiny two","synchronizedLines":null,"synchronizedWordByWordLines":null}"#)
        let result = try await configuredProvider().fetch(request())
        XCTAssertEqual(result.timing, .plain)
        XCTAssertEqual(result.lines.map(\.text), ["Tiny one", "Tiny two"])
    }

    func testGraphQLErrorRefreshesOnceThenAuthenticationFailed() async {
        let authCalls = DeezerLocked(0), graphCalls = DeezerLocked(0)
        DeezerURLProtocol.handler = { request in
            switch request.url!.host {
            case "api.deezer.com": return Self.json(request, Self.searchJSON)
            case "auth.deezer.com":
                authCalls.mutate { $0 += 1 }
                return Self.json(request, #"{"jwt":"jwt-\#(authCalls.value)"}"#)
            case "pipe.deezer.com":
                graphCalls.mutate { $0 += 1 }
                return Self.json(request, #"{"errors":[{"message":"Unauthorized token"}]}"#)
            default: fatalError()
            }
        }
        await assertError(.authenticationFailed) { _ = try await self.configuredProvider().fetch(self.request()) }
        XCTAssertEqual(authCalls.value, 2)
        XCTAssertEqual(graphCalls.value, 2)
    }

    func testAuthenticationTransportErrorsKeepTheirClassification() async {
        for (status, expected): (Int, LyricsProviderError) in [
            (429, .rateLimited(retryAfter: nil)),
            (503, .transient),
        ] {
            DeezerURLProtocol.handler = { request in
                switch request.url!.host {
                case "api.deezer.com": return Self.json(request, Self.searchJSON)
                case "auth.deezer.com": return Self.response(request, status: status, text: "")
                default: fatalError()
                }
            }
            await assertError(expected) {
                _ = try await self.configuredProvider().fetch(self.request())
            }
        }
    }

    func testEmptyLyricsIsMiss() async {
        DeezerURLProtocol.handler = happyHandler(lyrics: #"{"text":"  ","synchronizedLines":[],"synchronizedWordByWordLines":[]}"#)
        await assertError(.miss) { _ = try await self.configuredProvider().fetch(self.request()) }
    }

    func testARLAndJWTNeverAppearInErrors() async throws {
        let arl = "private-arl-marker", jwt = "private-jwt-marker"
        let store = InMemoryCredentialStore()
        await store.set(Data(arl.utf8), service: DeezerAuthSession.credentialService, account: DeezerAuthSession.credentialAccount)
        DeezerURLProtocol.handler = { request in
            switch request.url!.host {
            case "api.deezer.com": return Self.json(request, Self.searchJSON)
            case "auth.deezer.com": return Self.json(request, #"{"jwt":"\#(jwt)"}"#)
            default: return Self.json(request, "{broken")
            }
        }
        do { _ = try await provider(store: store).fetch(request()); XCTFail() }
        catch {
            let description = String(describing: error)
            XCTAssertFalse(description.contains(arl)); XCTAssertFalse(description.contains(jwt))
        }
    }

    private func configuredProvider() async throws -> DeezerProvider {
        let store = InMemoryCredentialStore()
        await store.set(Data("synthetic-arl".utf8), service: DeezerAuthSession.credentialService,
                        account: DeezerAuthSession.credentialAccount)
        return provider(store: store)
    }
    private func provider(store: InMemoryCredentialStore) -> DeezerProvider {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DeezerURLProtocol.self]
        return DeezerProvider(httpClient: ProviderHTTPClient(configuration: configuration), credentialStore: store)
    }
    private func request() -> LyricsProviderRequest { .init(trackKey: "k", title: "Signal", artist: "Alpha", durationMs: 180_000) }
    private func happyHandler(lyrics: String) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            switch request.url!.host {
            case "api.deezer.com": return Self.json(request, Self.searchJSON)
            case "auth.deezer.com": return Self.json(request, #"{"jwt":"synthetic-jwt"}"#)
            case "pipe.deezer.com": return Self.json(request, #"{"data":{"track":{"lyrics":\#(lyrics)}}}"#)
            default: fatalError()
            }
        }
    }
    private func assertError(_ expected: LyricsProviderError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("expected \(expected)") } catch { XCTAssertEqual(error as? LyricsProviderError, expected) }
    }
    private static let searchJSON = #"{"data":[{"id":7,"title":"Signal","duration":180,"artist":{"name":"Alpha"}}]}"#
    private static func json(_ request: URLRequest, _ text: String) -> (HTTPURLResponse, Data) { (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, Data(text.utf8)) }
    private static func response(_ request: URLRequest, status: Int, text: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                         headerFields: ["Content-Type": "application/json"])!, Data(text.utf8))
    }
}

private final class DeezerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var stored: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { do { let (response,data) = try Self.handler!(request); client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) } catch { client?.urlProtocol(self,didFailWithError:error) } }
    override func stopLoading() {}
}
private final class DeezerLocked<Value>: @unchecked Sendable { private let lock = NSLock(); private var storage: Value; init(_ value: Value) { storage = value }; var value: Value { lock.lock(); defer { lock.unlock() }; return storage }; func mutate(_ body: (inout Value)->Void) { lock.lock(); body(&storage); lock.unlock() } }
