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

nonisolated final class ProviderLyricsDiskCache: @unchecked Sendable {
    static let schemaVersion = 3
    static let parserVersion = 1

    private let directory: URL
    private let queue = DispatchQueue(label: "ivlyrics.provider-lyrics-cache")
    private let maxEntries = 350

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = root.appendingPathComponent("lyrics_cache/provider_lyrics_v3", isDirectory: true)
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
