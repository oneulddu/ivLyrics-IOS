import Foundation
import XCTest
@testable import LyricsProviderCore

final class OrchestratorTests: XCTestCase {
    func testDirectPreflightRunsBeforeMusixmatch() async throws {
        let events = EventRecorder()
        let lrclib = DirectFakeProvider(id: .lrclib, events: events, directResult: lyrics(.lrclib, "direct", .plain), fetchResult: nil)
        let musix = FakeProvider(id: .musixmatch) { _ in await events.add("musix"); return self.lyrics(.musixmatch, "m", .lineSynced) }
        let result = try await orchestrator([lrclib, musix]).fetch(request(contextID: 42), policy: policy([.musixmatch, .lrclib]))
        XCTAssertEqual(result.chosen.providerTrackID, "direct")
        let recorded = await events.values
        XCTAssertEqual(recorded, ["direct"])
    }

    func testMusixmatchSyncedShortCircuitsFallback() async throws {
        let calls = AtomicCounter()
        let musix = FakeProvider(id: .musixmatch) { _ in self.lyrics(.musixmatch, "m", .lineSynced) }
        let bugs = FakeProvider(id: .bugs) { _ in await calls.increment(); return self.lyrics(.bugs, "b", .lineSynced) }
        let result = try await orchestrator([musix, bugs]).fetch(request(), policy: policy([.musixmatch, .bugs]))
        XCTAssertEqual(result.chosen.provider, .musixmatch)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testMusixmatchPlainHeldForSyncedFallback() async throws {
        let musix = FakeProvider(id: .musixmatch) { _ in self.lyrics(.musixmatch, "m", .plain) }
        let bugs = FakeProvider(id: .bugs) { _ in self.lyrics(.bugs, "b", .lineSynced) }
        let result = try await orchestrator([musix, bugs]).fetch(request(), policy: policy([.musixmatch, .bugs]))
        XCTAssertEqual(result.chosen.provider, .bugs)
    }

    func testSyncedDisallowedMusixmatchDemotesAndHoldsForSyncedFallback() async throws {
        let musix = FakeProvider(id: .musixmatch) { _ in self.lyrics(.musixmatch, "m", .lineSynced) }
        let bugs = FakeProvider(id: .bugs) { _ in self.lyrics(.bugs, "b", .lineSynced) }
        let types: [LyricsProviderID: ProviderAllowedLyricsTypes] = [
            .musixmatch: .init(karaoke: true, synced: false, plain: true)
        ]
        let result = try await orchestrator([musix, bugs]).fetch(
            request(), policy: policy([.musixmatch, .bugs], types: types))
        XCTAssertEqual(result.chosen.provider, .bugs)
        XCTAssertEqual(result.chosen.timing, .lineSynced)
    }

    func testDemotedMusixmatchPlainWinsWhenNoSyncedRemains() async throws {
        let musix = FakeProvider(id: .musixmatch) { _ in self.lyrics(.musixmatch, "m", .lineSynced) }
        let genie = FakeProvider(id: .genie) { _ in self.lyrics(.genie, "g", .plain) }
        let types: [LyricsProviderID: ProviderAllowedLyricsTypes] = [
            .musixmatch: .init(karaoke: true, synced: false, plain: true)
        ]
        let result = try await orchestrator([musix, genie]).fetch(
            request(), policy: policy([.musixmatch, .genie], types: types))
        XCTAssertEqual(result.chosen.provider, .musixmatch)
        XCTAssertEqual(result.chosen.timing, .plain)
        XCTAssertTrue(result.chosen.lines.allSatisfy {
            $0.startMs == 0 && $0.endMs == nil && $0.syllables.isEmpty && $0.vocalParts.isEmpty
        })
    }

    func testUnisonKaraokeOnlyPreservesRichTiming() async throws {
        let unison = FakeProvider(id: .unison) { _ in self.richLyrics(.unison, "u") }
        let types: [LyricsProviderID: ProviderAllowedLyricsTypes] = [
            .unison: .init(karaoke: true, synced: false, plain: false)
        ]
        let result = try await orchestrator([unison]).fetch(
            request(), policy: policy([.unison], types: types))
        XCTAssertEqual(result.chosen.provider, .unison)
        XCTAssertEqual(result.chosen.timing, .lineSynced)
        XCTAssertFalse(result.chosen.lines.flatMap(\.syllables).isEmpty)
    }

    func testProviderResultRejectedWhenNoBaseTypeAllowed() async throws {
        let bugs = FakeProvider(id: .bugs) { _ in self.lyrics(.bugs, "b", .lineSynced) }
        let genie = FakeProvider(id: .genie) { _ in self.lyrics(.genie, "g", .plain) }
        let types: [LyricsProviderID: ProviderAllowedLyricsTypes] = [
            .bugs: .init(karaoke: true, synced: false, plain: false)
        ]
        let result = try await orchestrator([bugs, genie]).fetch(
            request(), policy: policy([.bugs, .genie], types: types))
        XCTAssertEqual(result.chosen.provider, .genie)
        XCTAssertTrue(result.diagnostics.contains { $0.provider == .bugs && $0.outcome == .policyDisabled })
    }

    func testArrivalPermutationsSelectSameWinner() async throws {
        var winners: [LyricsProviderID] = []
        for delays in [[80, 10], [10, 80], [30, 30]] {
            let bugs = FakeProvider(id: .bugs) { _ in try await Task.sleep(nanoseconds: UInt64(delays[0]) * 1_000_000); return self.lyrics(.bugs, "b", .lineSynced) }
            let genie = FakeProvider(id: .genie) { _ in try await Task.sleep(nanoseconds: UInt64(delays[1]) * 1_000_000); return self.lyrics(.genie, "g", .lineSynced) }
            winners.append(try await orchestrator([bugs, genie]).fetch(request(), policy: policy([.bugs, .genie])).chosen.provider)
        }
        XCTAssertEqual(winners, [.bugs, .bugs, .bugs])
    }

    func testLowerRankArrivalDoesNotCancelHigherRank() async throws {
        let finished = EventRecorder()
        let bugs = FakeProvider(id: .bugs) { _ in
            try await Task.sleep(nanoseconds: 80_000_000); await finished.add("bugs"); return self.lyrics(.bugs, "b", .lineSynced)
        }
        let genie = FakeProvider(id: .genie) { _ in
            try await Task.sleep(nanoseconds: 5_000_000); await finished.add("genie"); return self.lyrics(.genie, "g", .lineSynced)
        }
        let result = try await orchestrator([bugs, genie]).fetch(request(), policy: policy([.bugs, .genie]))
        XCTAssertEqual(result.chosen.provider, .bugs)
        let completed = await finished.values
        XCTAssertTrue(completed.contains("bugs"))
    }

    func testLowerRankWorkCancelsAfterUnbeatableSyncedResult() async throws {
        let cancelled = AtomicCounter()
        let bugs = FakeProvider(id: .bugs) { _ in self.lyrics(.bugs, "b", .lineSynced) }
        let genie = FakeProvider(id: .genie) { _ in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { await cancelled.increment(); throw error }
            return self.lyrics(.genie, "g", .lineSynced)
        }
        let result = try await orchestrator([bugs, genie]).fetch(request(), policy: policy([.bugs, .genie]))
        XCTAssertEqual(result.chosen.provider, .bugs)
        let cancellationCount = await cancelled.value
        XCTAssertEqual(cancellationCount, 1)
    }

    func testFallbackConcurrencyCapIsTwo() async throws {
        let counter = ConcurrencyCounter()
        let ids: [LyricsProviderID] = [.deezer, .bugs, .genie, .lrclib]
        let providers = ids.map { id in FakeProvider(id: id) { _ in
            await counter.enter(); try await Task.sleep(nanoseconds: 30_000_000); await counter.leave()
            return self.lyrics(id, id.rawValue, .plain)
        }}
        _ = try await orchestrator(providers).fetch(request(), policy: policy(ids))
        let maximum = await counter.maximum
        XCTAssertEqual(maximum, 2)
    }

    func testCircuitOpenProviderIsSkipped() async throws {
        let breaker = ProviderCircuitBreaker(formatFailureThreshold: 1, ordinaryFailureThreshold: 1, baseCooldown: 100)
        await breaker.record(.providerFormat, for: .bugs)
        let calls = AtomicCounter()
        let bugs = FakeProvider(id: .bugs) { _ in await calls.increment(); return self.lyrics(.bugs, "b", .lineSynced) }
        let genie = FakeProvider(id: .genie) { _ in self.lyrics(.genie, "g", .plain) }
        let sut = LyricsProviderOrchestrator(providers: [bugs, genie], circuitBreaker: breaker)
        let result = try await sut.fetch(request(), policy: policy([.bugs, .genie]))
        XCTAssertEqual(result.chosen.provider, .genie)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
        XCTAssertTrue(result.diagnostics.contains { $0.provider == .bugs && $0.outcome == .circuitOpen })
    }

    func testProviderExcludedByPolicyIsNeverInvoked() async throws {
        let calls = AtomicCounter()
        let deezer = FakeProvider(id: .deezer) { _ in await calls.increment(); return self.lyrics(.deezer, "d", .lineSynced) }
        let bugs = FakeProvider(id: .bugs) { _ in self.lyrics(.bugs, "b", .plain) }
        _ = try await orchestrator([deezer, bugs]).fetch(request(), policy: policy([.bugs]))
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testCancellationPropagates() async {
        let provider = FakeProvider(id: .musixmatch) { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000); return self.lyrics(.musixmatch, "m", .plain)
        }
        let task = Task { try await self.orchestrator([provider]).fetch(self.request(), policy: self.policy([.musixmatch])) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch is CancellationError { }
        catch { XCTFail("unexpected \(error)") }
    }

    func testStableRankUsesScoreThenTrackID() {
        let low = lyrics(.bugs, "20", .plain, score: 0.8)
        let highB = lyrics(.bugs, "10", .plain, score: 0.9)
        let highA = lyrics(.bugs, "02", .plain, score: 0.9)
        XCTAssertEqual(LyricsProviderOrchestrator.ranked([low, highB, highA], providerOrder: [.bugs]).map(\.providerTrackID), ["02", "10", "20"])
    }

    private func orchestrator(_ providers: [any LyricsProvider]) -> LyricsProviderOrchestrator {
        LyricsProviderOrchestrator(providers: providers,
            configuration: .init(defaultProviderTimeout: 1, totalBudget: 3, fallbackConcurrencyLimit: 2))
    }
    private func policy(_ ids: [LyricsProviderID],
                        types: [LyricsProviderID: ProviderAllowedLyricsTypes] = [:]) -> EffectiveProviderPolicy {
        .init(effectiveMode: .multiProvider, deniedProviders: [], orderedProviders: ids,
              policyVersion: 1, credentialGeneration: 0, allowedTypesByProvider: types)
    }
    private func request(contextID: Int64 = 0) -> LyricsProviderRequest {
        LyricsProviderRequest(trackKey: "t", title: "Signal", artist: "Alpha", durationMs: 180_000,
            syncDataSelectionContext: contextID > 0 ? .init(lrclibID: contextID) : nil)
    }
    private func lyrics(_ provider: LyricsProviderID, _ id: String, _ timing: LyricsTiming,
                        score: Double = 0.9) -> ProviderLyrics {
        let evidence = MatchEvidence(titleScore: 1, artistScore: 1, durationScore: 1, durationDeltaMs: 0,
            versionPenalty: 0, directIdentifier: .none, totalScore: score, policyVersion: 1)
        let candidate = LyricsCandidate(provider: provider, providerTrackID: id, title: "Signal", artist: "Alpha",
            durationMs: 180_000, availableTiming: [timing], matchEvidence: evidence)
        return ProviderLyrics(provider: provider, providerTrackID: id,
            lines: [ProviderLyricLine(startMs: 0, text: "A")], timing: timing, matchedCandidate: candidate)
    }
    private func richLyrics(_ provider: LyricsProviderID, _ id: String) -> ProviderLyrics {
        let evidence = MatchEvidence(titleScore: 1, artistScore: 1, durationScore: 1, durationDeltaMs: 0,
            versionPenalty: 0, directIdentifier: .none, totalScore: 0.9, policyVersion: 1)
        let candidate = LyricsCandidate(provider: provider, providerTrackID: id, title: "Signal", artist: "Alpha",
            durationMs: 180_000, availableTiming: [.lineSynced], matchEvidence: evidence)
        return ProviderLyrics(provider: provider, providerTrackID: id,
            lines: [ProviderLyricLine(startMs: 0, endMs: 900, text: "A",
                                      syllables: [ProviderLyricSyllable(text: "A", startMs: 0, endMs: 450)])],
            timing: .lineSynced, matchedCandidate: candidate)
    }
}

private final class FakeProvider: LyricsProvider, @unchecked Sendable {
    let id: LyricsProviderID
    let operation: @Sendable (LyricsProviderRequest) async throws -> ProviderLyrics
    init(id: LyricsProviderID, operation: @escaping @Sendable (LyricsProviderRequest) async throws -> ProviderLyrics) {
        self.id = id; self.operation = operation
    }
    func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics { try await operation(request) }
}

private final class DirectFakeProvider: LyricsProviderDirectPreflighting, @unchecked Sendable {
    let id: LyricsProviderID
    let events: EventRecorder
    let directResult: ProviderLyrics?
    let fetchResult: ProviderLyrics?
    init(id: LyricsProviderID, events: EventRecorder, directResult: ProviderLyrics?, fetchResult: ProviderLyrics?) {
        self.id = id; self.events = events; self.directResult = directResult; self.fetchResult = fetchResult
    }
    func fetchDirect(_ request: LyricsProviderRequest, providerTrackID: String) async throws -> ProviderLyrics {
        await events.add("direct"); guard let directResult else { throw LyricsProviderError.miss }; return directResult
    }
    func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        await events.add("search"); guard let fetchResult else { throw LyricsProviderError.miss }; return fetchResult
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
private actor AtomicCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
private actor ConcurrencyCounter {
    private var current = 0
    private(set) var maximum = 0
    func enter() { current += 1; maximum = max(maximum, current) }
    func leave() { current -= 1 }
}
