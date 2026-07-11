import Foundation
import XCTest
@testable import LyricsProviderCore

final class UnisonTests: XCTestCase {
    override func tearDown() {
        UnisonURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testDefaultOrderAndProviderIdentity() {
        XCTAssertEqual(LyricsProviderID.defaultOrder,
                       [.musixmatch, .deezer, .unison, .bugs, .genie, .lrclib])
        XCTAssertEqual(UnisonProvider().id, .unison)
    }

    func testMetadataAttemptsPreferAlbumAndDurationAndStopAfterMatch() async throws {
        let urls = LockedUnisonValues<URL>()
        UnisonURLProtocolStub.handler = { request in
            urls.append(request.url!)
            return Self.json(request, Self.envelope(format: "plain", lyrics: "Synthetic line"))
        }
        let result = try await UnisonProvider(client: UnisonClient(httpClient: stubClient()))
            .fetch(makeRequest(artist: "Alpha feat. Beta"))
        XCTAssertEqual(result.provider, .unison)
        XCTAssertEqual(urls.values.count, 1)
        let query = URLComponents(url: try XCTUnwrap(urls.values.first), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "song" })?.value, "Signal")
        XCTAssertEqual(query?.first(where: { $0.name == "artist" })?.value, "Alpha feat. Beta")
        XCTAssertEqual(query?.first(where: { $0.name == "album" })?.value, "Album")
        XCTAssertEqual(query?.first(where: { $0.name == "duration" })?.value, "180")
        XCTAssertEqual(UnisonURLProtocolStub.lastRequest?.value(forHTTPHeaderField: "User-Agent"), "ivLyrics-iOS")
        XCTAssertFalse(result.providerTrackID.contains("?"))
        XCTAssertFalse(result.providerTrackID.contains("Signal"))
    }

    func testDurationlessFallbackRejectsNonExactMetadata() async {
        let calls = LockedUnisonValues<URL>()
        UnisonURLProtocolStub.handler = { request in
            calls.append(request.url!)
            if request.url?.query?.contains("duration=") == true {
                return Self.response(request, status: 404, body: "")
            }
            return Self.json(request, Self.envelope(format: "plain", lyrics: "Synthetic line",
                                                    song: "Different", artist: "Someone"))
        }
        do { _ = try await UnisonProvider(client: UnisonClient(httpClient: stubClient())).fetch(makeRequest()); XCTFail() }
        catch { XCTAssertEqual(error as? LyricsProviderError, .miss) }
        XCTAssertEqual(calls.values.count, 3) // album+duration, duration, exact metadata fallback
    }

    func testTTMLSyllablesSpeakersAndBackgroundVocals() throws {
        let ttml = #"""
        <tt xmlns:ttm="urn:ttm"><head><metadata><ttm:agent xml:id="v1"/><ttm:agent xml:id="v2"/></metadata></head>
        <body><div><p begin="1s" end="4s" ttm:agent="v1" xml:id="l1">
          <span begin="1s" end="1.5s">Syn</span><span begin="1.5s" end="2s">thetic</span>
          <span ttm:role="x-bg" ttm:agent="v2" begin="2s" end="4s">(<span begin="2s" end="3s">Back</span><span begin="3s" end="4s">ground</span>)</span>
        </p></div></body></tt>
        """#
        let parsed = try UnisonParser.parse(try data(format: "ttml", lyrics: ttml), durationMs: 5_000)
        XCTAssertEqual(parsed.timing, .lineSynced)
        let line = try XCTUnwrap(parsed.lines.first)
        XCTAssertEqual(line.vocalParts.map(\.role), [.lead, .background])
        XCTAssertEqual(line.vocalParts[0].syllables.map(\.text), ["Syn", "thetic"])
        XCTAssertEqual(line.vocalParts[1].syllables.map(\.text), ["Back", "ground"])
        XCTAssertEqual(line.vocalParts[0].speaker?.speaker, "NORMAL")
        XCTAssertEqual(line.vocalParts[1].speaker?.fallback, "MALE 1")
        XCTAssertTrue(line.syllables.isEmpty)
        XCTAssertEqual(line.startMs, 1_000)
        XCTAssertEqual(line.endMs, 4_000)
    }

    func testTTMLDeclaresMissingNamespaceAndRetainsSingleLeadSyllables() throws {
        let ttml = #"<tt><body><p begin="0s" end="2s" ttm:agent="voice"><span begin="0s" end="1s">One</span><span begin="1s" end="2s">Two</span></p></body></tt>"#
        let parsed = try UnisonParser.parse(try data(format: "ttml", lyrics: ttml), durationMs: nil)
        XCTAssertEqual(parsed.lines[0].syllables.map(\.text), ["One", "Two"])
        XCTAssertTrue(parsed.lines[0].vocalParts.isEmpty)
        XCTAssertNotNil(parsed.lines[0].speaker)
    }

    func testTTMLRecursivelyCollectsBackgroundsWithoutDuplicates() throws {
        let ttml = #"""
        <tt xmlns:ttm="urn:ttm"><head><metadata><ttm:agent xml:id="v1"/><ttm:agent xml:id="v2"/><ttm:agent xml:id="v3"/></metadata></head>
        <body><p begin="0s" end="5s" ttm:agent="v1"><span begin="0s" end="1s">Lead</span>
          <span><span ttm:role="x-bg" ttm:agent="v2" begin="1s" end="2s"><span begin="1s" end="2s">Back</span></span></span>
          <span><span><span ttm:role="x-bg" ttm:agent="v3" begin="3s" end="4s"><span begin="3s" end="4s">Echo</span></span></span></span>
        </p></body></tt>
        """#
        let line = try XCTUnwrap(UnisonParser.parse(try data(format: "ttml", lyrics: ttml), durationMs: nil).lines.first)
        XCTAssertEqual(line.vocalParts.map(\.role), [.lead, .background, .background])
        XCTAssertEqual(line.vocalParts.map(\.text), ["Lead", "Back", "Echo"])
        XCTAssertEqual(line.vocalParts[1].speaker?.fallback, "MALE 1")
        XCTAssertEqual(line.vocalParts[2].speaker?.fallback, "FEMALE 1")
        XCTAssertEqual(line.vocalParts[1].syllables.map(\.startMs), [1_000])
        XCTAssertEqual(line.vocalParts[2].syllables.map(\.endMs), [4_000])
    }

    func testLRCAndPlainParsing() throws {
        let lrc = try UnisonParser.parse(try data(format: "lrc", lyrics: "[offset:100]\n[00:01.00][00:02.00]First\n[00:02.50]Second"),
                                         durationMs: 4_000)
        XCTAssertEqual(lrc.lines.map(\.startMs), [1_100, 2_100, 2_600])
        XCTAssertEqual(lrc.lines.map(\.endMs), [2_100, 2_600, 4_000])
        XCTAssertEqual(lrc.timing, .lineSynced)
        let plain = try UnisonParser.parse(try data(format: "plain", lyrics: "First\n\nSecond"), durationMs: nil)
        XCTAssertEqual(plain.lines.map(\.text), ["First", "Second"])
        XCTAssertEqual(plain.timing, .plain)
    }

    func testMalformedPayloadUnsupportedFormatAndMalformedTTML() async throws {
        UnisonURLProtocolStub.handler = { request in Self.json(request, #"{"success":true,"data":{"lyrics":7}}"#) }
        do { _ = try await UnisonProvider(client: UnisonClient(httpClient: stubClient())).fetch(makeRequest(durationMs: nil)); XCTFail() }
        catch { XCTAssertEqual(error as? LyricsProviderError, .providerFormat) }
        assertError(.providerFormat) { try UnisonParser.parse(try data(format: "binary", lyrics: "x"), durationMs: nil) }
        assertError(.providerFormat) { try UnisonParser.parse(try data(format: "ttml", lyrics: "<tt><p>"), durationMs: nil) }
    }

    func testUnsafeDurationsAndMetadataMapToProviderFormat() async {
        let payloads = [
            #"{"success":true,"data":{"lyrics":"Line","format":"plain","song":"Signal","artist":"Alpha","album":"Album","duration":"nan"}}"#,
            #"{"success":true,"data":{"lyrics":"Line","format":"plain","song":"Signal","artist":"Alpha","album":"Album","duration":1e300}}"#,
            #"{"success":true,"data":{"lyrics":"Line","format":"plain","song":"Signal","artist":"Alpha","album":"Album","durationMs":9223372036854775807}}"#,
            Self.envelope(format: "plain", lyrics: "Line", song: String(repeating: "s", count: 513)),
            Self.envelope(format: "plain", lyrics: "Line", artist: String(repeating: "a", count: 513)),
            Self.envelope(format: "plain", lyrics: "Line", album: String(repeating: "b", count: 1_025)),
            Self.envelope(format: String(repeating: "f", count: 33), lyrics: "Line")
        ]
        for payload in payloads {
            UnisonURLProtocolStub.handler = { request in Self.json(request, payload) }
            do {
                _ = try await UnisonProvider(client: UnisonClient(httpClient: stubClient())).fetch(makeRequest())
                XCTFail("expected providerFormat")
            } catch {
                XCTAssertEqual(error as? LyricsProviderError, .providerFormat)
            }
        }
    }

    func testUnsafeTTMLAndLRCTimesMapToProviderFormat() throws {
        for time in ["nan", "1e300s", "25h", "9223372036854775807ms", "24:00:01"] {
            let ttml = "<tt><body><p begin=\"\(time)\" end=\"1s\">Line</p></body></tt>"
            assertError(.providerFormat) {
                try UnisonParser.parse(try data(format: "ttml", lyrics: ttml), durationMs: nil)
            }
        }
        for lrc in [
            "[999999999999999999999999:00]Line",
            "[00:999999999999999999999999]Line",
            "[00:01.999999999999999999999]Line",
            "[offset:9223372036854775807]\n[00:01]Line",
            "[offset:-9223372036854775808]\n[00:01]Line"
        ] {
            assertError(.providerFormat) {
                try UnisonParser.parse(try data(format: "lrc", lyrics: lrc), durationMs: nil)
            }
        }
    }

    func testXMLResourceLimitsAndDeepTree() throws {
        let deep = "<tt><body><p>" + String(repeating: "<span>", count: 129) + "Line"
            + String(repeating: "</span>", count: 129) + "</p></body></tt>"
        assertError(.providerFormat) {
            try UnisonParser.parse(try data(format: "ttml", lyrics: deep), durationMs: nil)
        }
        let tooManyNodes = "<tt><body><p>" + String(repeating: "<span/>", count: 50_000) + "</p></body></tt>"
        assertError(.providerFormat) {
            try UnisonParser.parse(try data(format: "ttml", lyrics: tooManyNodes), durationMs: nil)
        }
        let tooMuchText = "<tt><body><p>" + String(repeating: "x", count: 500_001) + "</p></body></tt>"
        assertError(.providerFormat) {
            try UnisonParser.parse(try data(format: "ttml", lyrics: tooMuchText), durationMs: nil)
        }
    }

    func testLRCAndPlainStrictlyLimitLinesAndItems() throws {
        let tooManyPlainLines = Array(repeating: "Line", count: 10_001).joined(separator: "\n")
        assertError(.providerFormat) {
            try UnisonParser.parse(try data(format: "plain", lyrics: tooManyPlainLines), durationMs: nil)
        }
        let tooManyLRCItems = String(repeating: "[00:01]", count: 10_001) + "Line"
        assertError(.providerFormat) {
            try UnisonParser.parse(try data(format: "lrc", lyrics: tooManyLRCItems), durationMs: nil)
        }
        let tooManyLRCLines = Array(repeating: "[00:01]Line", count: 10_001).joined(separator: "\n")
        assertError(.providerFormat) {
            try UnisonParser.parse(try data(format: "lrc", lyrics: tooManyLRCLines), durationMs: nil)
        }
    }

    func testSizeAndStatusMappingAreSafe() async {
        UnisonURLProtocolStub.handler = { request in Self.response(request, status: 200, body: String(repeating: "x", count: 50)) }
        do { _ = try await UnisonProvider(client: UnisonClient(httpClient: stubClient(maxBytes: 10))).fetch(makeRequest()); XCTFail() }
        catch { XCTAssertEqual(error as? LyricsProviderError, .providerFormat) }
        UnisonURLProtocolStub.handler = { request in Self.response(request, status: 503, body: "private response") }
        do { _ = try await UnisonProvider(client: UnisonClient(httpClient: stubClient())).fetch(makeRequest()); XCTFail() }
        catch let error as LyricsProviderError {
            XCTAssertEqual(error, .transient)
            XCTAssertFalse(error.description.contains("private"))
            XCTAssertFalse(error.description.contains("Signal"))
        } catch { XCTFail() }
    }

    func testCancelledParserDoesNotOverrun() async {
        let source = "<tt><body>" + (0..<2_000).map { "<p begin=\"\($0)s\"><span begin=\"\($0)s\">X</span></p>" }.joined() + "</body></tt>"
        let value = try? data(format: "ttml", lyrics: source)
        let task = Task { try UnisonParser.parse(try XCTUnwrap(value), durationMs: nil) }
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch is CancellationError { }
        catch { XCTFail("unexpected \(error)") }
    }

    func testCancellationDuringXMLDelegateParsingAborts() async throws {
        let source = "<tt><body><p>" + String(repeating: "<span>X</span>", count: 45_000) + "</p></body></tt>"
        let value = try data(format: "ttml", lyrics: source)
        let started = expectation(description: "parser task started")
        let task = Task.detached {
            try UnisonParser.parse(value, durationMs: nil) {
                started.fulfill()
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.0001) }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch is CancellationError { }
        catch { XCTFail("unexpected \(error)") }
    }

    func testRichLineCodableRoundTripAndLegacyDefaults() throws {
        let line = ProviderLyricLine(startMs: 10, endMs: 20, text: "Synthetic",
            syllables: [.init(text: "Syn", startMs: 10, endMs: 15)],
            speaker: .init(speaker: "NORMAL"),
            vocalParts: [.init(id: "lead", role: .lead, text: "Synthetic",
                               syllables: [.init(text: "Synthetic", startMs: 10, endMs: 20)])])
        XCTAssertEqual(try JSONDecoder().decode(ProviderLyricLine.self, from: JSONEncoder().encode(line)), line)
        let legacy = try JSONDecoder().decode(ProviderLyricLine.self,
            from: Data(#"{"startMs":0,"text":"Legacy"}"#.utf8))
        XCTAssertTrue(legacy.syllables.isEmpty)
        XCTAssertNil(legacy.speaker)
        XCTAssertTrue(legacy.vocalParts.isEmpty)
    }

    func testRankingPlacesUnisonAtConfiguredPosition() {
        let evidence = MatchEvidence(titleScore: 1, artistScore: 1, durationScore: 1,
            durationDeltaMs: 0, versionPenalty: 0, directIdentifier: .none,
            totalScore: 1, policyVersion: LyricsMatcher.policyVersion)
        func lyrics(_ provider: LyricsProviderID) -> ProviderLyrics {
            let candidate = LyricsCandidate(provider: provider, providerTrackID: provider.rawValue,
                title: "Signal", artist: "Alpha", availableTiming: [.lineSynced], matchEvidence: evidence)
            return ProviderLyrics(provider: provider, providerTrackID: provider.rawValue,
                lines: [.init(startMs: 0, text: "Synthetic")], timing: .lineSynced,
                matchedCandidate: candidate)
        }
        let ranked = LyricsProviderOrchestrator.ranked([lyrics(.bugs), lyrics(.unison), lyrics(.deezer)],
                                                        providerOrder: LyricsProviderID.defaultOrder)
        XCTAssertEqual(ranked.map(\.provider), [.deezer, .unison, .bugs])
    }

    private func makeRequest(artist: String = "Alpha", durationMs: Int64? = 180_000) -> LyricsProviderRequest {
        LyricsProviderRequest(trackKey: "track", title: "Signal", artist: artist,
                              album: "Album", durationMs: durationMs)
    }
    private func data(format: String, lyrics: String) throws -> UnisonLyricsData {
        try JSONDecoder().decode(UnisonResponseEnvelope.self,
            from: Data(Self.envelope(format: format, lyrics: lyrics).utf8)).data!
    }
    private func assertError<T>(_ expected: LyricsProviderError, _ body: () throws -> T,
                                file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try body(); XCTFail("expected error", file: file, line: line) }
        catch { XCTAssertEqual(error as? LyricsProviderError, expected, file: file, line: line) }
    }
    private func stubClient(maxBytes: Int = 100_000) -> ProviderHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnisonURLProtocolStub.self]
        return ProviderHTTPClient(configuration: configuration, maxResponseBytes: maxBytes)
    }
    private static func envelope(format: String, lyrics: String,
                                 song: String = "Signal", artist: String = "Alpha",
                                 album: String = "Album") -> String {
        let object: [String: Any] = ["success": true, "data": ["lyrics": lyrics, "format": format,
            "song": song, "artist": artist, "album": album, "duration": 180]]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    private static func json(_ request: URLRequest, _ text: String) -> (HTTPURLResponse, Data) {
        response(request, status: 200, body: text, headers: ["Content-Type": "application/json"])
    }
    private static func response(_ request: URLRequest, status: Int, body: String,
                                 headers: [String: String]? = nil) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                         headerFields: headers)!, Data(body.utf8))
    }
}

private final class UnisonURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var storedLastRequest: URLRequest?
    static var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return storedLastRequest
    }
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); defer { lock.unlock() }; storedHandler = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            Self.storedLastRequest = request
            Self.lock.unlock()
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

private final class LockedUnisonValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Value) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}
