import Foundation
import XCTest
@testable import LyricsProviderCore

final class GenieTests: XCTestCase {
    override func tearDown() {
        GenieURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSearchWellFormedEntitiesNestedTagsAndIcons() throws {
        let html = #"""
        <div class="music-list-wrap"><table><tr class="list" songid="42">
          <td class="info">
            <a class="title ellipsis"><span class="icon icon-title">TITLE</span><span>Signal &amp; Light</span></a>
            <a class="artist ellipsis" title="Alpha &amp; Beta"><i>ignored</i></a>
            <span class="duration">03:04</span>
          </td>
        </tr></table></div>
        """#
        let tracks = try GenieSearchParser.parse(html)
        XCTAssertEqual(tracks, [GenieTrack(id: "42", title: "Signal & Light", artist: "Alpha & Beta", durationMs: 184_000)])
    }

    func testSearchMissingRequiredFieldSkipsRow() throws {
        let html = #"<div class="music-list"><tr class="list" songid="42"><td class="info"><a class="title">Signal</a></td></tr></div>"#
        XCTAssertTrue(try GenieSearchParser.parse(html).isEmpty)
    }

    func testSearchRecognizedEmptyRegionReturnsZeroRows() throws {
        XCTAssertTrue(try GenieSearchParser.parse(#"<div class="music-list-wrap"><table></table></div>"#).isEmpty)
    }

    func testStructurallyBrokenSearchPageIsProviderFormat() {
        assertError(.providerFormat) { try GenieSearchParser.parse("<html><body>changed</body></html>") }
    }

    func testJSONPFixedMillisecondsAndSortOrder() throws {
        let lines = try GenieLyricsParser.parse(#"null({"8346":"둘째 줄","7300":"첫 줄"})"#)
        XCTAssertEqual(lines.map(\.startMs), [7_300, 8_346])
        XCTAssertNotEqual(lines.first?.startMs, 7_300_000)
        XCTAssertEqual(GenieLyricsParser.plainText(from: lines), "첫 줄\n둘째 줄")
    }

    func testInvalidCallbackAndUnexpectedNestingAreProviderFormat() {
        assertError(.providerFormat) { try GenieLyricsParser.parse(#"callback({"7300":"A"})"#) }
        assertError(.providerFormat) { try GenieLyricsParser.parse(#"null({"7300":{"text":"A"}})"#) }
    }

    func testFewNonNumericKeysAreSkipped() throws {
        let lines = try GenieLyricsParser.parse(#"null({"bad":"skip","7300":"A","8346":"B"})"#)
        XCTAssertEqual(lines.map(\.startMs), [7_300, 8_346])
    }

    func testTooManyNonNumericKeysAreProviderFormat() {
        assertError(.providerFormat) { try GenieLyricsParser.parse(#"null({"bad":"x","no":"y","7300":"A"})"#) }
    }

    func testOversizedPayloadRejectedByParser() {
        assertError(.providerFormat) { try GenieLyricsParser.parse(#"null({"1":"A"})"#, maxBytes: 5) }
    }

    func testLyricsRequestHasRefererAndMillisecondsRemainUnchanged() async throws {
        GenieURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.host, "dn.genie.co.kr")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.genie.co.kr/")
            XCTAssertTrue(request.url?.query?.contains("path=a") == true)
            XCTAssertTrue(request.url?.query?.contains("songid=42") == true)
            return Self.response(request, status: 200, body: #"null({"7300":"A","8346":"B"})"#)
        }
        let lines = try await GenieClient(httpClient: stubClient()).fetchLyrics(trackID: "42", durationMs: nil)
        XCTAssertEqual(lines.map(\.startMs), [7_300, 8_346])
    }

    func testOversizedNetworkResponseRejected() async {
        GenieURLProtocolStub.handler = { request in Self.response(request, status: 200, body: String(repeating: "x", count: 30)) }
        do { _ = try await GenieClient(httpClient: stubClient(maxBytes: 10)).fetchLyrics(trackID: "42", durationMs: nil); XCTFail() }
        catch { XCTAssertEqual(error as? LyricsProviderError, .providerFormat) }
    }

    private func assertError<T>(_ expected: LyricsProviderError, _ body: () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try body(); XCTFail("expected error", file: file, line: line) }
        catch { XCTAssertEqual(error as? LyricsProviderError, expected, file: file, line: line) }
    }

    private func stubClient(maxBytes: Int = 10_000) -> ProviderHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenieURLProtocolStub.self]
        return ProviderHTTPClient(configuration: configuration, maxResponseBytes: maxBytes)
    }

    private static func response(_ request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                         headerFields: ["Content-Type": "text/plain"])!, Data(body.utf8))
    }
}

private final class GenieURLProtocolStub: URLProtocol, @unchecked Sendable {
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
