import Foundation
import LyricsProviderCore

actor LyricsProviderCredentialManager {
    static let shared = LyricsProviderCredentialManager()

    private let store: KeychainCredentialStore
    private let deezerSession: DeezerAuthSession
    private let deezerClient: DeezerClient
    private let orchestrator: LyricsProviderOrchestrator
    private var currentPolicyGeneration: UInt64 = 0
    private var activeRequests: [UUID: Task<LyricsProviderOrchestratorResult, Error>] = [:]

    private init() {
        let store = KeychainCredentialStore()
        let deezerSession = DeezerAuthSession(credentialStore: store)
        self.store = store
        self.deezerSession = deezerSession
        let deezerClient = DeezerClient(authSession: deezerSession)
        self.deezerClient = deezerClient
        orchestrator = LyricsProviderOrchestrator(providers: [
            LrclibProviderAdapter(),
            PaxsenixLyricsProviderAdapter(),
            LyricsPlusCoreProviderAdapter(),
            MusixmatchProvider(credentialStore: store),
            DeezerProvider(client: deezerClient, authSession: deezerSession),
            UnisonProvider(),
            BugsProvider(),
            GenieProvider(),
        ])
    }

    func deezerIsConfigured() async -> Bool {
        (try? await store.get(
            service: DeezerAuthSession.credentialService,
            account: DeezerAuthSession.credentialAccount
        ))?.isEmpty == false
    }

    func saveDeezerARL(_ value: String) async throws {
        try await deezerSession.setARL(value)
        do {
            try await deezerClient.validateAuthentication(arl: value)
        } catch {
            try? await deezerSession.removeARL()
            throw error
        }
    }

    func removeDeezerARL() async throws {
        try await deezerSession.removeARL()
    }

    func fetch(
        _ request: LyricsProviderRequest,
        policy: EffectiveProviderPolicy,
        policyGeneration: UInt64
    ) async throws -> LyricsProviderOrchestratorResult {
        if policyGeneration != currentPolicyGeneration {
            guard policyGeneration > currentPolicyGeneration else {
                throw CancellationError()
            }
            cancelActiveRequests(policyGeneration: policyGeneration)
        }
        let id = UUID()
        let task = Task { [orchestrator] in
            try await orchestrator.fetch(request, policy: policy)
        }
        activeRequests[id] = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            activeRequests.removeValue(forKey: id)
            guard policyGeneration == currentPolicyGeneration else {
                throw CancellationError()
            }
            return result
        } catch {
            activeRequests.removeValue(forKey: id)
            throw error
        }
    }

    func cancelActiveRequests(policyGeneration: UInt64) {
        guard policyGeneration >= currentPolicyGeneration else { return }
        currentPolicyGeneration = policyGeneration
        let tasks = Array(activeRequests.values)
        activeRequests.removeAll()
        for task in tasks {
            task.cancel()
        }
    }
}

struct PaxsenixLyricsProviderAdapter: LyricsProvider, Sendable {
    let id: LyricsProviderID = .paxsenix

    func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        let track = AppLyricsProviderAdapterSupport.track(from: request)
        guard let outcome = try await PaxsenixLyricsProvider.fetch(track: track) else {
            throw LyricsProviderError.miss
        }
        return try AppLyricsProviderAdapterSupport.providerLyrics(
            provider: id,
            request: request,
            sourceType: outcome.sourceType,
            karaoke: outcome.karaoke,
            synced: outcome.synced,
            plain: outcome.plain
        )
    }
}

struct LyricsPlusCoreProviderAdapter: LyricsProvider, Sendable {
    let id: LyricsProviderID = .lyricsplus

    func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        let track = AppLyricsProviderAdapterSupport.track(from: request)
        guard let outcome = try await LyricsPlusProvider.fetch(
            track: track,
            isrc: request.isrc ?? ""
        ) else {
            throw LyricsProviderError.miss
        }
        return try AppLyricsProviderAdapterSupport.providerLyrics(
            provider: id,
            request: request,
            sourceType: outcome.sourceType,
            karaoke: outcome.karaoke,
            synced: outcome.synced,
            plain: outcome.plain
        )
    }
}

enum AppLyricsProviderAdapterSupport {
    static func track(from request: LyricsProviderRequest) -> TrackSnapshot {
        TrackSnapshot(
            title: request.title,
            artist: request.artist,
            album: request.album,
            mediaId: request.spotifyTrackId ?? "",
            isrc: request.isrc ?? "",
            durationMs: request.durationMs ?? 0
        )
    }

    static func providerLyrics(
        provider: LyricsProviderID,
        request: LyricsProviderRequest,
        sourceType: String,
        karaoke: [LyricsLine]?,
        synced: [LyricsLine]?,
        plain: [LyricsLine]?
    ) throws -> ProviderLyrics {
        let selected: ([LyricsLine], LyricsTiming)
        if let karaoke, !karaoke.isEmpty {
            selected = (karaoke, .lineSynced)
        } else if let synced, !synced.isEmpty {
            selected = (synced, .lineSynced)
        } else if let plain, !plain.isEmpty {
            selected = (plain, .plain)
        } else {
            throw LyricsProviderError.miss
        }
        let evidence = MatchEvidence(
            titleScore: 0,
            artistScore: 0,
            durationScore: 0,
            durationDeltaMs: nil,
            versionPenalty: 0,
            directIdentifier: .none,
            totalScore: 0,
            policyVersion: LyricsMatcher.policyVersion
        )
        let normalizedSource = sourceType.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerTrackID = [provider.rawValue, normalizedSource, request.trackKey]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        let candidate = LyricsCandidate(
            provider: provider,
            providerTrackID: providerTrackID,
            title: request.title,
            artist: request.artist,
            album: request.album.isEmpty ? nil : request.album,
            durationMs: request.durationMs,
            availableTiming: [selected.1],
            matchEvidence: evidence
        )
        return ProviderLyrics(
            provider: provider,
            providerTrackID: providerTrackID,
            lines: selected.0.map(providerLine),
            timing: selected.1,
            matchedCandidate: candidate
        )
    }

    private static func providerLine(_ line: LyricsLine) -> ProviderLyricLine {
        ProviderLyricLine(
            startMs: line.startTimeMs,
            endMs: line.endTimeMs > line.startTimeMs ? line.endTimeMs : nil,
            text: line.text,
            syllables: line.syllables.map(providerSyllable),
            speaker: providerSpeaker(
                speaker: line.speaker,
                color: line.speakerColor,
                fallback: line.speakerFallback
            ),
            vocalParts: line.vocalParts.map { part in
                ProviderVocalPart(
                    id: part.id,
                    role: ProviderVocalRole(rawValue: part.role) ?? .lead,
                    speaker: providerSpeaker(
                        speaker: part.speaker,
                        color: part.speakerColor,
                        fallback: part.speakerFallback
                    ),
                    text: part.text,
                    syllables: part.syllables.map(providerSyllable)
                )
            }
        )
    }

    private static func providerSyllable(_ syllable: LyricsLine.Syllable) -> ProviderLyricSyllable {
        ProviderLyricSyllable(
            text: syllable.text,
            startMs: syllable.startTimeMs,
            endMs: syllable.endTimeMs
        )
    }

    private static func providerSpeaker(
        speaker: String,
        color: String,
        fallback: String
    ) -> ProviderSpeakerPresentation? {
        guard !speaker.isEmpty || !color.isEmpty || !fallback.isEmpty else { return nil }
        return ProviderSpeakerPresentation(
            speaker: speaker,
            color: color.isEmpty ? nil : color,
            fallback: fallback.isEmpty ? nil : fallback
        )
    }
}

nonisolated final class ProviderLyricsDiskCache: @unchecked Sendable {
    static let schemaVersion = 4
    static let parserVersion = 1

    private let directory: URL
    private let queue = DispatchQueue(label: "ivlyrics.provider-lyrics-cache")
    private let maxEntries = 350

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let cacheRoot = root.appendingPathComponent("lyrics_cache", isDirectory: true)
        directory = cacheRoot.appendingPathComponent("provider_lyrics_v4", isDirectory: true)
        try? FileManager.default.removeItem(
            at: cacheRoot.appendingPathComponent("provider_lyrics_v3", isDirectory: true)
        )
    }

    func get(_ key: LyricsCacheKey) -> LyricsCacheEnvelope<LyricsResult>? {
        queue.sync {
            let file = fileURL(key.encoded)
            guard let data = try? Data(contentsOf: file),
                  let envelope = try? JSONDecoder().decode(LyricsCacheEnvelope<LyricsResult>.self, from: data) else {
                return nil
            }
            return envelope
        }
    }

    func put(_ envelope: LyricsCacheEnvelope<LyricsResult>) {
        queue.sync {
            guard !envelope.result.lines.isEmpty else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONEncoder().encode(envelope).write(to: fileURL(envelope.cacheKey), options: .atomic)
                prune()
            } catch {
                // Cache failures must never make lyrics loading fail.
            }
        }
    }

    func remove(trackIdentity: String) {
        queue.sync {
            for file in files() where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let envelope = try? JSONDecoder().decode(LyricsCacheEnvelope<LyricsResult>.self, from: data),
                      let key = LyricsCacheKey(encoded: envelope.cacheKey) else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                if key.components.normalizedTrackIdentity == trackIdentity {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    func clear() {
        queue.sync {
            for file in files() { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(IvLyricsUtilities.sha256(key)).json")
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
    }

    private func prune() {
        let values = files()
        guard values.count > maxEntries else { return }
        let sorted = values.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in sorted.prefix(values.count - maxEntries) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
