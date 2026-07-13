import CryptoKit
import XCTest
@testable import LyricsProviderCore

final class CoreLogicTests: XCTestCase {
    func testModeNormalizationIsFailClosed() {
        XCTAssertEqual(LyricsProviderMode.normalize(nil), .legacy)
        XCTAssertEqual(LyricsProviderMode.normalize("MULTIPROVIDER"), .legacy)
        XCTAssertEqual(LyricsProviderMode.normalize("corrupt"), .legacy)
        XCTAssertEqual(LyricsProviderMode.normalize("multiProvider"), .multiProvider)
    }

    func testPolicyAuthorizationAndGlobalDisablePrecedence() {
        let requested = settings(mode: .multiProvider)
        XCTAssertEqual(LyricsProviderPolicyEvaluator.evaluate(requested, multiProviderAuthorized: false).effectiveMode, .legacy)
        XCTAssertEqual(LyricsProviderPolicyEvaluator.evaluate(requested, multiProviderAuthorized: true).effectiveMode, .multiProvider)
        let disabled = settings(mode: .multiProvider, globalDisable: true)
        XCTAssertEqual(LyricsProviderPolicyEvaluator.evaluate(disabled, multiProviderAuthorized: true).effectiveMode, .legacy)
    }

    func testPolicyOrderDeduplicatesAndAppendsMissing() {
        let snapshot = LyricsProviderSettingsSnapshot(mode: .multiProvider,
            enabledProviders: [.bugs, .genie, .lrclib], providerOrder: [.genie, .genie],
            deezerConfigured: false)
        let value = LyricsProviderPolicyEvaluator.evaluate(snapshot, multiProviderAuthorized: true)
        XCTAssertEqual(value.orderedProviders, [.genie, .bugs, .lrclib])
    }

    func testDeezerNotConfiguredIsExcluded() {
        let value = LyricsProviderPolicyEvaluator.evaluate(settings(mode: .multiProvider), multiProviderAuthorized: true)
        XCTAssertFalse(value.orderedProviders.contains(.deezer))
    }

    func testPolicyExcludesProvidersWithoutAllowedBaseTypes() {
        let snapshot = LyricsProviderSettingsSnapshot(
            mode: .multiProvider,
            enabledProviders: [.bugs, .unison, .lrclib],
            providerOrder: [.bugs, .unison, .lrclib],
            deezerConfigured: false,
            allowedTypesByProvider: [
                .bugs: .init(karaoke: true, synced: false, plain: false),
                .unison: .init(karaoke: true, synced: false, plain: false),
                .lrclib: .init(karaoke: false, synced: false, plain: false)
            ]
        )
        let value = LyricsProviderPolicyEvaluator.evaluate(snapshot, multiProviderAuthorized: true)
        XCTAssertEqual(value.orderedProviders, [.unison])
        XCTAssertTrue(value.allowedTypes(for: .genie).synced)
    }

    func testRemotePolicySignatureAndExpiry() throws {
        let key = Curve25519.Signing.PrivateKey()
        let policy = LyricsProviderRemotePolicy(schemaVersion: 1, globalDisable: false,
            disabledProviders: [.bugs], multiProviderCohortAllowed: true,
            policyVersion: 4, expiresAtMs: 2_000)
        let payload = try JSONEncoder().encode(policy)
        let signature = try key.signature(for: payload)
        XCTAssertNotNil(LyricsProviderRemotePolicyDecoder.decode(payload: payload, signature: signature,
            publicKeyRawRepresentation: key.publicKey.rawRepresentation, nowMs: 1_000))
        XCTAssertNil(LyricsProviderRemotePolicyDecoder.decode(payload: payload, signature: signature,
            publicKeyRawRepresentation: key.publicKey.rawRepresentation, nowMs: 2_000))
        XCTAssertNil(LyricsProviderRemotePolicyDecoder.decode(payload: payload + Data([0]), signature: signature,
            publicKeyRawRepresentation: key.publicKey.rawRepresentation, nowMs: 1_000))
    }

    func testMatcherUnicodeNFKCAndExactMultilingual() {
        XCTAssertEqual(LyricsMatcher.normalize("ＡＢＣ Café"), "abc cafe")
        for pair in [("밤하늘", "밤하늘"), ("ひかり", "ひかり"), ("Hello", "hello")] {
            let evidence = match(title: pair.0, candidateTitle: pair.1)
            XCTAssertTrue(LyricsMatcher.accepts(evidence))
        }
    }

    func testMatcherHandlesFeaturedAndMultipleArtists() {
        let request = request(title: "Signal", artist: "Alpha feat. Beta")
        let candidate = candidate(provider: .bugs, id: "1", title: "Signal", artist: "Alpha & Beta")
        let evidence = LyricsMatcher.score(request: request, candidate: candidate)
        XCTAssertGreaterThan(evidence.artistScore, 0.75)
        XCTAssertTrue(LyricsMatcher.accepts(evidence))
    }

    func testMatcherRejectsCandidateOnlyVersions() {
        for suffix in ["(Live)", "- Remix", "(Karaoke)", "(Instrumental)", "(Cover)"] {
            let evidence = match(title: "Signal", candidateTitle: "Signal \(suffix)")
            XCTAssertFalse(LyricsMatcher.accepts(evidence), suffix)
        }
    }

    func testMatcherAllowsMatchingVersionMarker() {
        let request = request(title: "Signal (Live)", artist: "Alpha")
        let value = candidate(provider: .bugs, id: "1", title: "Signal Live", artist: "Alpha")
        XCTAssertTrue(LyricsMatcher.accepts(LyricsMatcher.score(request: request, candidate: value)))
    }

    func testMatcherDurationGate() {
        let near = match(title: "Signal", candidateTitle: "Signal", requestDuration: 180_000, candidateDuration: 183_000)
        let far = match(title: "Signal", candidateTitle: "Signal", requestDuration: 180_000, candidateDuration: 205_000)
        XCTAssertTrue(LyricsMatcher.accepts(near))
        XCTAssertFalse(LyricsMatcher.accepts(far))
    }

    func testCacheKeySetCanonicalAndModeIsolation() {
        let enabledA: Set<LyricsProviderID> = [.bugs, .lrclib, .genie]
        let enabledB: Set<LyricsProviderID> = [.genie, .bugs, .lrclib]
        XCTAssertEqual(LyricsCacheKey.enabledProviderSetCanonical(enabledA),
                       LyricsCacheKey.enabledProviderSetCanonical(enabledB))
        XCTAssertNotEqual(cacheKey(mode: .legacy).encoded, cacheKey(mode: .multiProvider).encoded)
    }

    func testCacheKeyOrderAndEscapingRoundTrip() {
        let components = LyricsCacheKey.Components(schemaVersion: 2, effectiveMode: .multiProvider,
            normalizedTrackIdentity: "a|b\\c", providerPolicyVersion: 3,
            enabledProviderSetCanonical: "bugs,lrclib",
            preferredProviderOrderCanonical: "bugs,lrclib", credentialGeneration: 7)
        let key = LyricsCacheKey(components: components)
        XCTAssertEqual(LyricsCacheKey(encoded: key.encoded)?.components, components)
        XCTAssertEqual(LyricsCacheKey.preferredProviderOrderCanonical([.genie, .genie], enabled: [.genie, .bugs]), "genie,bugs")
    }

    func testCacheKeyAllowedTypesCanonicalSeparatesPolicies() {
        let allOn = LyricsCacheKey.allowedProviderTypesCanonical([:])
        let restricted = LyricsCacheKey.allowedProviderTypesCanonical([
            .musixmatch: .init(karaoke: true, synced: false, plain: true)
        ])
        XCTAssertNotEqual(allOn, restricted)
        XCTAssertTrue(allOn.hasPrefix("musixmatch:111,"))
        XCTAssertTrue(restricted.hasPrefix("musixmatch:101,"))
        let components = LyricsCacheKey.Components(schemaVersion: 3, effectiveMode: .multiProvider,
            normalizedTrackIdentity: "t", providerPolicyVersion: 1,
            enabledProviderSetCanonical: "lrclib",
            preferredProviderOrderCanonical: "lrclib",
            allowedProviderTypesCanonical: restricted,
            credentialGeneration: 0)
        let key = LyricsCacheKey(components: components)
        XCTAssertEqual(LyricsCacheKey(encoded: key.encoded)?.components, components)
        XCTAssertNotEqual(
            key.encoded,
            LyricsCacheKey(components: .init(schemaVersion: 3, effectiveMode: .multiProvider,
                normalizedTrackIdentity: "t", providerPolicyVersion: 1,
                enabledProviderSetCanonical: "lrclib",
                preferredProviderOrderCanonical: "lrclib",
                allowedProviderTypesCanonical: allOn,
                credentialGeneration: 0)).encoded
        )
    }

    func testCacheEnvelopeCodableRoundTrip() throws {
        let key = cacheKey(mode: .multiProvider).encoded
        let envelope = LyricsCacheEnvelope(schemaVersion: 2, cacheKey: key,
            result: [ProviderLyricLine(startMs: 0, text: "A")], provenance: provenance(), savedAtMs: 44)
        let decoded = try JSONDecoder().decode(LyricsCacheEnvelope<[ProviderLyricLine]>.self,
            from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded.cacheKey, key)
        XCTAssertEqual(decoded.provenance.matchEvidence, provenance().matchEvidence)
        XCTAssertEqual(decoded.savedAtMs, 44)
    }

    func testCacheAdmissionDenylistBeforeFreshness() {
        let policy = EffectiveProviderPolicy(effectiveMode: .multiProvider, deniedProviders: [.bugs],
            orderedProviders: [.bugs], policyVersion: 1, credentialGeneration: 0)
        XCTAssertEqual(CacheAdmissionPolicy.evaluate(provenance: provenance(), currentPolicy: policy,
            freshness: .init(isFresh: true, isKaraoke: true)), .reject)
    }

    func testCacheAdmissionImmediateAndBaseReapply() {
        let policy = EffectiveProviderPolicy(effectiveMode: .multiProvider, deniedProviders: [],
            orderedProviders: [.bugs], policyVersion: 1, credentialGeneration: 0)
        XCTAssertEqual(CacheAdmissionPolicy.evaluate(provenance: provenance(), currentPolicy: policy,
            freshness: .init(isFresh: true, isKaraoke: true)), .immediateReturn)
        XCTAssertEqual(CacheAdmissionPolicy.evaluate(provenance: provenance(), currentPolicy: policy,
            freshness: .init(isFresh: true, isKaraoke: false)), .baseReapply)
    }

    func testLRCCommonVectorsAndEndInference() throws {
        let lines = try ProviderLRC.parse("[00:00.00]A\n[00:59.999]B\n[01:00.50]C", durationMs: 65_000)
        XCTAssertEqual(lines.map(\.startMs), [0, 59_999, 60_500])
        XCTAssertEqual(lines.map(\.endMs), [59_999, 60_500, 65_000])
    }

    func testLRCSortsSmallRegressionAndDropsSevereRegression() throws {
        let lines = try ProviderLRC.buildLines(from: [(5_000, "B"), (4_500, "A"), (1_000, "bad"), (6_000, "C")])
        XCTAssertEqual(lines.map(\.startMs), [4_500, 5_000, 6_000])
    }

    func testLRCRejectsLowValidRatio() {
        XCTAssertThrowsError(try ProviderLRC.parse("bad\nnope\n[00:01.00]A\nstill bad")) { error in
            XCTAssertEqual(error as? LyricsProviderError, .providerFormat)
        }
    }

    func testPlainSplitterNormalizesCRLFAndEmptyLines() {
        XCTAssertEqual(ProviderLRC.splitPlainText(" A\r\n\r\n B ").map(\.text), ["A", "B"])
    }

    func testTextNormalizerParityVectors() {
        let text = "[ar:meta]\n[00:01.00]가\n[00:02.00](나)"
        XCTAssertEqual(LyricsTextNormalizer.comparableLyricsLines(text, stripTimestamps: true), ["가", "(나)"])
        XCTAssertEqual(LyricsTextNormalizer.comparableLyricsLines(text, stripTimestamps: true,
            normalizeParentheticalLines: true), ["가", "나"])
        XCTAssertEqual(LyricsTextNormalizer.lineCharCounts(["가", "e\u{301}"]), [1, 1])
        XCTAssertTrue(LyricsTextNormalizer.hasOriginalLyricsScript("가"))
        XCTAssertFalse(LyricsTextNormalizer.hasOriginalLyricsScript("abc"))
    }

    func testTextFingerprintStableVector() {
        XCTAssertEqual(LyricsTextNormalizer.lyricsFingerprint("A\nB"), "lrclib-1bqn64w-3")
    }

    func testJSONPExtractionAcceptsObjectAndRejectsOtherPayloads() throws {
        let data = try ProviderParsingSupport.extractJSONPObject(callbackText: "cb({\"7300\":\"A\"});")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for invalid in ["cb([1])", "cb(\"x\")", "cb({}) trailing", "bad-name({})"] {
            XCTAssertThrowsError(try ProviderParsingSupport.extractJSONPObject(callbackText: invalid))
        }
    }

    func testCircuitBreakerTransitionsAndHalfOpenSingleProbe() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let breaker = ProviderCircuitBreaker(formatFailureThreshold: 2, ordinaryFailureThreshold: 3,
            baseCooldown: 10, now: { clock.now })
        await breaker.record(.providerFormat, for: .bugs)
        let initial = await breaker.permission(for: .bugs)
        XCTAssertEqual(initial, .allowed)
        await breaker.record(.providerFormat, for: .bugs)
        if case .denied = await breaker.permission(for: .bugs) {} else { XCTFail() }
        clock.advance(10)
        let probe = await breaker.permission(for: .bugs)
        XCTAssertEqual(probe, .probe)
        if case .denied = await breaker.permission(for: .bugs) {} else { XCTFail() }
        await breaker.recordSuccess(for: .bugs)
        let recovered = await breaker.permission(for: .bugs)
        XCTAssertEqual(recovered, .allowed)
    }

    func testCircuitBreakerIgnoresMissPolicyAndCancellation() async {
        let breaker = ProviderCircuitBreaker(formatFailureThreshold: 1, ordinaryFailureThreshold: 1)
        for error: LyricsProviderError in [.miss, .policyDisabled, .cancelled] {
            await breaker.record(error, for: .bugs)
        }
        let state = await breaker.state(for: .bugs)
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testInMemoryCredentialStoreCRUD() async throws {
        let store = InMemoryCredentialStore()
        let empty = await store.get(service: "deezer", account: "arl")
        XCTAssertNil(empty)
        await store.set(Data("secret".utf8), service: "deezer", account: "arl")
        let saved = await store.get(service: "deezer", account: "arl")
        XCTAssertEqual(saved, Data("secret".utf8))
        await store.remove(service: "deezer", account: "arl")
        let removed = await store.get(service: "deezer", account: "arl")
        XCTAssertNil(removed)
    }

    private func settings(mode: LyricsProviderMode, globalDisable: Bool = false) -> LyricsProviderSettingsSnapshot {
        LyricsProviderSettingsSnapshot(mode: mode,
            enabledProviders: Set(LyricsProviderID.defaultOrder), providerOrder: LyricsProviderID.defaultOrder,
            deezerConfigured: false, globalRemoteDisable: globalDisable)
    }

    private func request(title: String = "Signal", artist: String = "Alpha", duration: Int64? = 180_000,
                         context: SyncDataSelectionContext? = nil) -> LyricsProviderRequest {
        LyricsProviderRequest(trackKey: "track", title: title, artist: artist, album: "Album",
                              durationMs: duration, syncDataSelectionContext: context)
    }

    private func candidate(provider: LyricsProviderID, id: String, title: String, artist: String,
                           duration: Int64? = 180_000, timing: LyricsTiming = .lineSynced) -> LyricsCandidate {
        LyricsCandidate(provider: provider, providerTrackID: id, title: title, artist: artist,
                        durationMs: duration, availableTiming: [timing], matchEvidence: evidence())
    }

    private func match(title: String, candidateTitle: String,
                       requestDuration: Int64? = 180_000, candidateDuration: Int64? = 180_000) -> MatchEvidence {
        let req = request(title: title, duration: requestDuration)
        return LyricsMatcher.score(request: req,
            candidate: candidate(provider: .bugs, id: "1", title: candidateTitle, artist: "Alpha", duration: candidateDuration))
    }

    private func evidence(score: Double = 0.95) -> MatchEvidence {
        MatchEvidence(titleScore: 1, artistScore: 1, durationScore: 1, durationDeltaMs: 0,
                      versionPenalty: 0, directIdentifier: .none, totalScore: score,
                      policyVersion: LyricsMatcher.policyVersion)
    }

    private func cacheKey(mode: LyricsProviderMode) -> LyricsCacheKey {
        LyricsCacheKey(components: .init(schemaVersion: 2, effectiveMode: mode,
            normalizedTrackIdentity: LyricsCacheKey.normalizedTrackIdentity(title: "Signal", artist: "Alpha", album: "", durationMs: 180_000),
            providerPolicyVersion: 1, enabledProviderSetCanonical: "bugs",
            preferredProviderOrderCanonical: "bugs", credentialGeneration: 0))
    }

    private func provenance() -> LyricsCacheProvenance {
        LyricsCacheProvenance(effectiveMode: .multiProvider, baseProvider: .bugs,
            providerTrackID: "1", timing: .lineSynced, normalizedCandidateTitle: "signal",
            normalizedCandidateArtist: "alpha", matchEvidence: evidence(), matchPolicyVersion: 1,
            parserVersion: 1, providerPolicyVersion: 1, syncDataApplied: true, fetchedAtMs: 20)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
