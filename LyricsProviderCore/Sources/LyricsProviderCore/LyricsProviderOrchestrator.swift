import Foundation

public protocol LyricsProviderDirectPreflighting: LyricsProvider {
    func fetchDirect(_ request: LyricsProviderRequest, providerTrackID: String) async throws -> ProviderLyrics
}

public struct LyricsProviderOrchestratorConfiguration: Sendable {
    public let perProviderTimeout: [LyricsProviderID: TimeInterval]
    public let defaultProviderTimeout: TimeInterval
    public let totalBudget: TimeInterval
    public let fallbackConcurrencyLimit: Int

    public init(perProviderTimeout: [LyricsProviderID: TimeInterval] = [:],
                defaultProviderTimeout: TimeInterval = 8, totalBudget: TimeInterval = 18,
                fallbackConcurrencyLimit: Int = 2) {
        self.perProviderTimeout = perProviderTimeout
        self.defaultProviderTimeout = defaultProviderTimeout
        self.totalBudget = totalBudget
        self.fallbackConcurrencyLimit = max(1, fallbackConcurrencyLimit)
    }
}

public struct ProviderOutcomeDiagnostic: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        case selected, candidate, miss, authenticationRequired, authenticationFailed
        case rateLimited, transient, providerFormat, policyDisabled, cancelled, circuitOpen, timedOut
    }
    public let provider: LyricsProviderID
    public let outcome: Outcome
    public let elapsedMs: Int64
    public let timing: LyricsTiming?
    public let score: Double?
    public let providerTrackID: String?

    public init(provider: LyricsProviderID, outcome: Outcome, elapsedMs: Int64,
                timing: LyricsTiming? = nil, score: Double? = nil,
                providerTrackID: String? = nil) {
        self.provider = provider; self.outcome = outcome; self.elapsedMs = elapsedMs
        self.timing = timing; self.score = score; self.providerTrackID = providerTrackID
    }
}

public struct LyricsProviderOrchestratorResult: Sendable {
    public let chosen: ProviderLyrics
    public let diagnostics: [ProviderOutcomeDiagnostic]
    public init(chosen: ProviderLyrics, diagnostics: [ProviderOutcomeDiagnostic]) {
        self.chosen = chosen; self.diagnostics = diagnostics
    }
}

public actor LyricsProviderOrchestrator {
    private let providers: [LyricsProviderID: any LyricsProvider]
    private let circuitBreaker: ProviderCircuitBreaker
    private let configuration: LyricsProviderOrchestratorConfiguration

    public init(providers: [any LyricsProvider], circuitBreaker: ProviderCircuitBreaker = ProviderCircuitBreaker(),
                configuration: LyricsProviderOrchestratorConfiguration = .init()) {
        var mapped: [LyricsProviderID: any LyricsProvider] = [:]
        for provider in providers where mapped[provider.id] == nil { mapped[provider.id] = provider }
        self.providers = mapped
        self.circuitBreaker = circuitBreaker
        self.configuration = configuration
    }

    public func fetch(_ request: LyricsProviderRequest,
                      policy: EffectiveProviderPolicy) async throws -> LyricsProviderOrchestratorResult {
        guard policy.effectiveMode == .multiProvider else { throw LyricsProviderError.policyDisabled }
        try Task.checkCancellation()
        let started = Date()
        var diagnostics: [ProviderOutcomeDiagnostic] = []
        let providerOrder = orderedProviders(for: request, policy: policy)
        var preflightCandidate: ProviderLyrics?

        if policy.preferSyncDataProvider,
           providerOrder.first == .lrclib,
           policy.allowedTypes(for: .lrclib).karaoke,
           let id = request.syncDataSelectionContext?.lrclibID, id > 0,
           policy.allows(.lrclib), let provider = providers[.lrclib] {
            let attempt = await attempt(provider: provider, request: request,
                                        directTrackID: String(id), budgetStart: started)
            diagnostics.append(attempt.diagnostic)
            try Task.checkCancellation()
            if let lyrics = attempt.lyrics {
                if let admittedLyrics = Self.admitted(lyrics, allowedTypes: policy.allowedTypes(for: .lrclib)) {
                    preflightCandidate = admittedLyrics
                }
                if preflightCandidate == nil {
                    diagnostics.append(.init(provider: .lrclib, outcome: .policyDisabled, elapsedMs: 0))
                }
            }
        }

        let fallbackIDs = providerOrder.filter {
            policy.allows($0) && providers[$0] != nil
                && !($0 == .lrclib && preflightCandidate != nil)
        }
        let fallback = await collectFallback(ids: fallbackIDs, request: request,
                                             policy: policy, budgetStart: started)
        diagnostics.append(contentsOf: fallback.diagnostics)
        try Task.checkCancellation()
        let candidates = fallback.lyrics + (preflightCandidate.map { [$0] } ?? [])
        guard let chosen = stableSort(candidates, order: providerOrder,
                                      preferLyricsType: policy.preferLyricsTypeOverProviderOrder).first else {
            throw LyricsProviderError.miss
        }
        diagnostics.append(selectedDiagnostic(chosen, elapsed: 0))
        return .init(chosen: chosen, diagnostics: diagnostics)
    }

    public nonisolated static func ranked(_ candidates: [ProviderLyrics],
                                          providerOrder: [LyricsProviderID],
                                          preferLyricsType: Bool = true) -> [ProviderLyrics] {
        let index = Dictionary(uniqueKeysWithValues: providerOrder.enumerated().map { ($0.element, $0.offset) })
        return candidates.sorted { left, right in
            let li = index[left.provider] ?? Int.max, ri = index[right.provider] ?? Int.max
            let leftTier = candidateTier(left)
            let rightTier = candidateTier(right)
            if preferLyricsType {
                if leftTier != rightTier { return leftTier < rightTier }
                if li != ri { return li < ri }
            } else {
                if li != ri { return li < ri }
                if leftTier != rightTier { return leftTier < rightTier }
            }
            if left.matchedCandidate.matchEvidence.totalScore != right.matchedCandidate.matchEvidence.totalScore {
                return left.matchedCandidate.matchEvidence.totalScore > right.matchedCandidate.matchEvidence.totalScore
            }
            let leftID = LyricsMatcher.normalize(left.providerTrackID)
            let rightID = LyricsMatcher.normalize(right.providerTrackID)
            return (leftID.isEmpty ? left.providerTrackID : leftID) < (rightID.isEmpty ? right.providerTrackID : rightID)
        }
    }

    private func stableSort(_ candidates: [ProviderLyrics], order: [LyricsProviderID],
                            preferLyricsType: Bool) -> [ProviderLyrics] {
        Self.ranked(candidates, providerOrder: order, preferLyricsType: preferLyricsType)
    }

    /// Applies the per-provider allowed lyric types to a fetched result before it can
    /// short-circuit, be held, or enter ranking. Synced results demote to plain when
    /// only plain is allowed; native rich timing survives on karaoke permission alone.
    nonisolated static func admitted(_ lyrics: ProviderLyrics,
                                     allowedTypes: ProviderAllowedLyricsTypes) -> ProviderLyrics? {
        switch lyrics.timing {
        case .lineSynced:
            if hasRichTiming(lyrics) {
                if allowedTypes.karaoke { return lyrics }
                if allowedTypes.synced { return strippedToSynced(lyrics) }
                return allowedTypes.plain ? demotedToPlain(lyrics) : nil
            }
            if allowedTypes.synced { return lyrics }
            return allowedTypes.plain ? demotedToPlain(lyrics) : nil
        case .plain:
            return allowedTypes.plain ? lyrics : nil
        }
    }

    nonisolated static func hasRichTiming(_ lyrics: ProviderLyrics) -> Bool {
        lyrics.lines.contains { line in
            line.syllables.contains { $0.endMs > $0.startMs }
                || line.vocalParts.contains { part in
                    part.syllables.contains { $0.endMs > $0.startMs }
                }
        }
    }

    nonisolated static func demotedToPlain(_ lyrics: ProviderLyrics) -> ProviderLyrics {
        ProviderLyrics(
            provider: lyrics.provider,
            providerTrackID: lyrics.providerTrackID,
            lines: lyrics.lines.map {
                ProviderLyricLine(startMs: 0, endMs: nil, text: $0.text,
                                  syllables: [], speaker: $0.speaker, vocalParts: [])
            },
            timing: .plain,
            rawCopyright: lyrics.rawCopyright,
            matchedCandidate: lyrics.matchedCandidate,
            fetchedAt: lyrics.fetchedAt
        )
    }

    nonisolated static func strippedToSynced(_ lyrics: ProviderLyrics) -> ProviderLyrics {
        ProviderLyrics(
            provider: lyrics.provider,
            providerTrackID: lyrics.providerTrackID,
            lines: lyrics.lines.map {
                ProviderLyricLine(startMs: $0.startMs, endMs: $0.endMs, text: $0.text,
                                  syllables: [], speaker: $0.speaker, vocalParts: [])
            },
            timing: .lineSynced,
            rawCopyright: lyrics.rawCopyright,
            matchedCandidate: lyrics.matchedCandidate,
            fetchedAt: lyrics.fetchedAt
        )
    }

    private nonisolated static func candidateTier(_ lyrics: ProviderLyrics) -> Int {
        if hasRichTiming(lyrics) { return 0 }
        return lyrics.timing == .lineSynced ? 1 : 2
    }

    private struct Attempt: Sendable {
        let lyrics: ProviderLyrics?
        let diagnostic: ProviderOutcomeDiagnostic
    }

    private func attempt(provider: any LyricsProvider, request: LyricsProviderRequest,
                         directTrackID: String?, budgetStart: Date) async -> Attempt {
        let providerID = provider.id
        let start = Date()
        let permission = await circuitBreaker.permission(for: providerID)
        if case .denied = permission {
            return Attempt(lyrics: nil, diagnostic: .init(provider: providerID, outcome: .circuitOpen, elapsedMs: 0))
        }
        let remaining = configuration.totalBudget - Date().timeIntervalSince(budgetStart)
        guard remaining > 0 else {
            await circuitBreaker.cancelProbe(for: providerID)
            return Attempt(lyrics: nil, diagnostic: .init(provider: providerID, outcome: .timedOut, elapsedMs: 0))
        }
        let timeout = min(remaining, configuration.perProviderTimeout[providerID] ?? configuration.defaultProviderTimeout)
        do {
            let result = try await withTimeout(seconds: timeout) {
                if let directTrackID, let direct = provider as? any LyricsProviderDirectPreflighting {
                    return try await direct.fetchDirect(request, providerTrackID: directTrackID)
                }
                return try await provider.fetch(request)
            }
            await circuitBreaker.recordSuccess(for: providerID)
            return Attempt(lyrics: result, diagnostic: candidateDiagnostic(result, start: start))
        } catch is CancellationError {
            await circuitBreaker.record(.cancelled, for: providerID)
            return Attempt(lyrics: nil, diagnostic: .init(provider: providerID, outcome: .cancelled,
                                                          elapsedMs: elapsedMs(since: start)))
        } catch let error as LyricsProviderError {
            await circuitBreaker.record(error, for: providerID)
            return Attempt(lyrics: nil, diagnostic: .init(provider: providerID,
                                                          outcome: outcome(for: error),
                                                          elapsedMs: elapsedMs(since: start)))
        } catch {
            await circuitBreaker.record(.transient, for: providerID)
            return Attempt(lyrics: nil, diagnostic: .init(provider: providerID, outcome: .transient,
                                                          elapsedMs: elapsedMs(since: start)))
        }
    }

    private func collectFallback(ids: [LyricsProviderID], request: LyricsProviderRequest,
                                 policy: EffectiveProviderPolicy,
                                 budgetStart: Date) async -> (lyrics: [ProviderLyrics], diagnostics: [ProviderOutcomeDiagnostic]) {
        var lyrics: [ProviderLyrics] = [], diagnostics: [ProviderOutcomeDiagnostic] = []
        await withTaskGroup(of: Attempt.self) { group in
            var nextIndex = 0
            var pending = Set<LyricsProviderID>()
            var stoppedScheduling = false
            func submitNext() {
                guard !stoppedScheduling, pending.count < configuration.fallbackConcurrencyLimit,
                      nextIndex < ids.count else { return }
                let id = ids[nextIndex]
                nextIndex += 1
                guard let provider = providers[id] else { submitNext(); return }
                pending.insert(id)
                let providerRequest = id == .lrclib ? self.requestWithoutDirectPreflight(request) : request
                group.addTask { await self.attempt(provider: provider, request: providerRequest,
                                                   directTrackID: nil, budgetStart: budgetStart) }
            }
            for _ in 0..<configuration.fallbackConcurrencyLimit { submitNext() }
            while let attempt = await group.next() {
                pending.remove(attempt.diagnostic.provider)
                diagnostics.append(attempt.diagnostic)
                if let result = attempt.lyrics {
                    if let admittedResult = Self.admitted(result, allowedTypes: policy.allowedTypes(for: result.provider)) {
                        lyrics.append(admittedResult)
                    } else {
                        diagnostics.append(.init(provider: result.provider, outcome: .policyDisabled, elapsedMs: 0))
                    }
                }
                if let best = Self.ranked(
                    lyrics,
                    providerOrder: ids,
                    preferLyricsType: policy.preferLyricsTypeOverProviderOrder
                ).first, let bestIndex = ids.firstIndex(of: best.provider) {
                    let unstarted = nextIndex < ids.count ? Array(ids[nextIndex...]) : []
                    let remaining = Array(pending) + unstarted
                    let allRemainingAreLowerPriority = remaining.allSatisfy {
                        (ids.firstIndex(of: $0) ?? .max) > bestIndex
                    }
                    let noRemainingNativeKaraoke = remaining.allSatisfy {
                        !$0.supportsNativeKaraoke || !policy.allowedTypes(for: $0).karaoke
                    }
                    let unbeatableByType = Self.candidateTier(best) == 0
                        || (Self.candidateTier(best) == 1 && noRemainingNativeKaraoke)
                    let shouldStop = allRemainingAreLowerPriority
                        && (!policy.preferLyricsTypeOverProviderOrder || unbeatableByType)
                    if shouldStop {
                        stoppedScheduling = true
                        nextIndex = ids.count
                        group.cancelAll()
                    }
                }
                submitNext()
            }
        }
        return (lyrics, diagnostics)
    }

    private func orderedProviders(
        for request: LyricsProviderRequest,
        policy: EffectiveProviderPolicy
    ) -> [LyricsProviderID] {
        var order = policy.orderedProviders
        guard policy.preferSyncDataProvider,
              let context = request.syncDataSelectionContext else { return order }
        let preferred = context.preferredProviderID
            ?? (context.lrclibID > 0 ? .lrclib : nil)
        guard let preferred, policy.allows(preferred),
              let index = order.firstIndex(of: preferred), index != 0 else { return order }
        order.remove(at: index)
        order.insert(preferred, at: 0)
        return order
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                          operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw LyricsProviderError.transient
            }
            guard let value = try await group.next() else { throw LyricsProviderError.transient }
            group.cancelAll()
            return value
        }
    }

    private func outcome(for error: LyricsProviderError) -> ProviderOutcomeDiagnostic.Outcome {
        switch error {
        case .miss: return .miss
        case .authenticationRequired: return .authenticationRequired
        case .authenticationFailed: return .authenticationFailed
        case .rateLimited: return .rateLimited
        case .transient: return .transient
        case .providerFormat: return .providerFormat
        case .policyDisabled: return .policyDisabled
        case .cancelled: return .cancelled
        }
    }
    private func candidateDiagnostic(_ value: ProviderLyrics, start: Date) -> ProviderOutcomeDiagnostic {
        .init(provider: value.provider, outcome: .candidate, elapsedMs: elapsedMs(since: start),
              timing: value.timing, score: value.matchedCandidate.matchEvidence.totalScore,
              providerTrackID: value.providerTrackID)
    }
    private func selectedDiagnostic(_ value: ProviderLyrics, elapsed: Int64) -> ProviderOutcomeDiagnostic {
        .init(provider: value.provider, outcome: .selected, elapsedMs: elapsed, timing: value.timing,
              score: value.matchedCandidate.matchEvidence.totalScore, providerTrackID: value.providerTrackID)
    }
    private func requestWithoutDirectPreflight(_ request: LyricsProviderRequest) -> LyricsProviderRequest {
        guard let context = request.syncDataSelectionContext else { return request }
        let searchContext = SyncDataSelectionContext(lrclibID: 0,
            lineCharCounts: context.lineCharCounts,
            sourceLineCharCounts: context.sourceLineCharCounts,
            sourceLyricsFingerprint: context.sourceLyricsFingerprint,
            preferredLyricsSource: context.preferredLyricsSource,
            preferredProviderID: context.preferredProviderID,
            shouldNormalizeParentheticalLines: context.shouldNormalizeParentheticalLines,
            hasLrclibSource: context.hasLrclibSource,
            contextVersion: context.contextVersion)
        return LyricsProviderRequest(trackKey: request.trackKey, title: request.title,
            artist: request.artist, album: request.album, durationMs: request.durationMs,
            isrc: request.isrc, spotifyTrackId: request.spotifyTrackId, locale: request.locale,
            syncDataSelectionContext: searchContext)
    }
    private func elapsedMs(since date: Date) -> Int64 { Int64(Date().timeIntervalSince(date) * 1_000) }
}
