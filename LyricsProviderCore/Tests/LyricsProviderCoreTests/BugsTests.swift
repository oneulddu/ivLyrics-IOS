import Foundation
import XCTest
@testable import LyricsProviderCore

final class BugsTests: XCTestCase {
    override func tearDown() {
        BugsURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSearchJSONParsingAndDuration() throws {
        let data = Data(#"{"list":[{"track_id":42,"track_title":"Signal","artists":[{"artist_nm":"Alpha"},{"artist_nm":"Beta"}],"len":"03:04"}]}"#.utf8)
        let tracks = try BugsParser.parseSearch(data)
        XCTAssertEqual(tracks, [BugsTrack(id: "42", title: "Signal", artist: "Alpha, Beta", durationMs: 184_000)])
    }

    func testSyncedFixedVectorsAndFullwidthSeparator() throws {
        let lines = try BugsParser.parseSyncedLyrics("7.3|첫 줄＃8.3456|둘째 줄")
        XCTAssertEqual(lines.map(\.startMs), [7_300, 8_346])
        XCTAssertEqual(lines.map(\.text), ["첫 줄", "둘째 줄"])
    }

    func testMalformedEntriesAreSkipped() throws {
        let lines = try BugsParser.parseSyncedLyrics("bad＃7.3|첫 줄＃8.4|둘째 줄")
        XCTAssertEqual(lines.count, 2)
    }

    func testLowValidRatioIsProviderFormat() {
        assertError(.providerFormat) { try BugsParser.parseSyncedLyrics("bad＃also bad＃7.3|ok") }
    }

    func testSevereTimestampRegressionIsProviderFormat() {
        assertError(.providerFormat) { try BugsParser.parseSyncedLyrics("10|first＃2|regressed") }
    }

    func testPlainCRLFNormalization() throws {
        XCTAssertEqual(try BugsParser.normalizePlainLyrics("A  \r\nB\r\n"), "A\nB")
    }

    func testSyncedOnlySuccess() async throws {
        BugsURLProtocolStub.handler = { request in
            if request.url!.path.contains("/T/") { return Self.json(request, #"{"lyrics":"7.3|A"}"#) }
            return Self.response(request, status: 404, body: "")
        }
        let result = try await BugsClient(httpClient: stubClient()).fetchLyrics(trackID: "42", durationMs: nil)
        XCTAssertEqual(result.synced?.first?.startMs, 7_300)
        XCTAssertNil(result.plain)
    }

    func testPlainOnlySuccess() async throws {
        BugsURLProtocolStub.handler = { request in
            if request.url!.path.contains("/N/") { return Self.json(request, #"{"lyrics":"A\r\nB"}"#) }
            return Self.response(request, status: 404, body: "")
        }
        let result = try await BugsClient(httpClient: stubClient()).fetchLyrics(trackID: "42", durationMs: nil)
        XCTAssertNil(result.synced)
        XCTAssertEqual(result.plain?.map(\.text), ["A", "B"])
    }

    func testBothInvalidProducesProviderFormat() async {
        BugsURLProtocolStub.handler = { request in Self.json(request, "{") }
        do { _ = try await BugsClient(httpClient: stubClient()).fetchLyrics(trackID: "42", durationMs: nil); XCTFail() }
        catch { XCTAssertEqual(error as? LyricsProviderError, .providerFormat) }
    }

    func testBothMissingProducesMiss() async {
        BugsURLProtocolStub.handler = { request in Self.response(request, status: 404, body: "") }
        do { _ = try await BugsClient(httpClient: stubClient()).fetchLyrics(trackID: "42", durationMs: nil); XCTFail() }
        catch { XCTAssertEqual(error as? LyricsProviderError, .miss) }
    }

    func testHTTPStatusMappingAndSafeDescriptions() async {
        for (status, expected): (Int, LyricsProviderError) in [
            (404, .miss), (429, .rateLimited(retryAfter: 4)), (503, .transient)
        ] {
            BugsURLProtocolStub.handler = { request in Self.response(request, status: status, body: "",
                headers: status == 429 ? ["Retry-After": "4"] : nil) }
            do { _ = try await BugsClient(httpClient: stubClient()).search(title: "secret title", artist: "hidden"); XCTFail() }
            catch let error as LyricsProviderError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.description.contains("secret"))
                XCTAssertFalse(error.description.contains("hidden"))
                XCTAssertFalse(error.description.contains("query="))
            } catch { XCTFail("unexpected error") }
        }
    }

    private func assertError<T>(_ expected: LyricsProviderError, _ body: () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try body(); XCTFail("expected error", file: file, line: line) }
        catch { XCTAssertEqual(error as? LyricsProviderError, expected, file: file, line: line) }
    }

    private func stubClient(maxBytes: Int = 10_000) -> ProviderHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BugsURLProtocolStub.self]
        return ProviderHTTPClient(configuration: configuration, maxResponseBytes: maxBytes)
    }

    private static func json(_ request: URLRequest, _ text: String) -> (HTTPURLResponse, Data) {
        response(request, status: 200, body: text, headers: ["Content-Type": "application/json"])
    }

    private static func response(_ request: URLRequest, status: Int, body: String,
                                 headers: [String: String]? = nil) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
    }
}

private final class BugsURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
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
