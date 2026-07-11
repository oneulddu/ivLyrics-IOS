import Foundation
import XCTest
@testable import LyricsProviderCore

final class NetworkAndAdapterTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testHTTPStatusMappingAndSafeDescriptions() async throws {
        URLProtocolStub.handler = { request in
            let code = Int(request.url?.lastPathComponent ?? "") ?? 500
            return (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                    headerFields: code == 429 ? ["Retry-After": "9"] : nil)!, Data())
        }
        let client = stubClient()
        for (code, expected): (Int, LyricsProviderError) in [(401, .authenticationRequired), (403, .authenticationFailed),
            (404, .miss), (429, .rateLimited(retryAfter: 9)), (503, .transient)] {
            do {
                _ = try await client.get(URL(string: "https://example.test/\(code)?token=private")!,
                                         headers: ["Authorization": "secret"])
                XCTFail("expected \(code)")
            } catch let error as LyricsProviderError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.description.contains("private"))
                XCTAssertFalse(error.description.contains("secret"))
            }
        }
    }

    func testHTTPMaxResponseGuard() async {
        URLProtocolStub.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(repeating: 1, count: 20))
        }
        do { _ = try await stubClient(maxBytes: 10).get(URL(string: "https://example.test/data")!); XCTFail() }
        catch { XCTAssertEqual(error as? LyricsProviderError, .providerFormat) }
    }

    func testProviderRedirectsAreAlwaysRejected() {
        let source = URL(string: "https://auth.example.test/session")!
        let destination = URL(string: "https://other.example.test/collect")!
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": destination.absoluteString])!
        let task = URLSession.shared.dataTask(with: source)
        let delegate = ProviderRedirectDelegate()
        let expectation = expectation(description: "redirect decision")
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: destination)) { redirected in
            XCTAssertNil(redirected)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testLrclibDirectIDHit() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/get/42")
            return Self.json(request, #"{"id":42,"trackName":"Signal","artistName":"Alpha","duration":180,"instrumental":false,"plainLyrics":"A\nB","syncedLyrics":"[00:01.00]A\n[00:02.00]B"}"#)
        }
        let adapter = LrclibProviderAdapter(httpClient: stubClient())
        let result = try await adapter.fetchDirect(makeRequest(context: .init(lrclibID: 42)), providerTrackID: "42")
        XCTAssertEqual(result.providerTrackID, "42")
        XCTAssertEqual(result.timing, .lineSynced)
        XCTAssertEqual(result.matchedCandidate.matchEvidence.directIdentifier, .syncDataLrclibID)
    }

    func testLrclibSearchUsesQueryFallback() async throws {
        let calls = LockedValues<String>()
        URLProtocolStub.handler = { request in
            calls.append(request.url!.absoluteString)
            if request.url?.query?.contains("track_name") == true { return Self.json(request, "[]") }
            return Self.json(request, #"[{"id":7,"trackName":"Signal","artistName":"Alpha","duration":180,"instrumental":false,"plainLyrics":"A\nB","syncedLyrics":null}]"#)
        }
        let result = try await LrclibProviderAdapter(httpClient: stubClient()).fetch(makeRequest())
        XCTAssertEqual(result.providerTrackID, "7")
        XCTAssertEqual(calls.values.count, 2)
        XCTAssertTrue(calls.values[1].contains("q="))
    }

    func testLrclibSelectionContextPrefersExactLineShape() async throws {
        URLProtocolStub.handler = { request in Self.json(request, #"""
        [
          {"id":1,"trackName":"Signal","artistName":"Alpha","duration":180,"instrumental":false,"plainLyrics":"LONG\nLINES","syncedLyrics":null},
          {"id":2,"trackName":"Signal","artistName":"Alpha","duration":180,"instrumental":false,"plainLyrics":"A\nBB","syncedLyrics":null}
        ]
        """#) }
        let context = SyncDataSelectionContext(lineCharCounts: [1, 2], preferredLyricsSource: "plain")
        let result = try await LrclibProviderAdapter(httpClient: stubClient()).fetch(makeRequest(context: context))
        XCTAssertEqual(result.providerTrackID, "2")
    }

    func testLrclibInstrumentalIsMiss() async {
        URLProtocolStub.handler = { request in Self.json(request,
            #"{"id":42,"trackName":"Signal","artistName":"Alpha","duration":180,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#) }
        do {
            _ = try await LrclibProviderAdapter(httpClient: stubClient()).fetchDirect(makeRequest(), providerTrackID: "42")
            XCTFail()
        } catch { XCTAssertEqual(error as? LyricsProviderError, .miss) }
    }

    private func makeRequest(context: SyncDataSelectionContext? = nil) -> LyricsProviderRequest {
        LyricsProviderRequest(trackKey: "t", title: "Signal", artist: "Alpha", album: "Album",
                              durationMs: 180_000, syncDataSelectionContext: context)
    }

    private func stubClient(maxBytes: Int = 10_000) -> ProviderHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return ProviderHTTPClient(configuration: configuration, maxResponseBytes: maxBytes)
    }

    private static func json(_ request: URLRequest, _ text: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                         headerFields: ["Content-Type": "application/json"])!, Data(text.utf8))
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
