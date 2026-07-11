import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public actor MusixmatchSession {
    public static let credentialService = "musixmatch"
    public static let credentialAccount = "usertoken"

    private let credentialStore: any SensitiveCredentialStore
    private var didLoadStoredToken = false
    private var cachedToken: String?
    private var issuance: Task<String, Error>?

    public init(credentialStore: any SensitiveCredentialStore) {
        self.credentialStore = credentialStore
    }

    public func token(issue: @escaping @Sendable () async throws -> String) async throws -> String {
        if !didLoadStoredToken {
            didLoadStoredToken = true
            do {
                if let data = try await credentialStore.get(service: Self.credentialService,
                                                            account: Self.credentialAccount),
                   let value = String(data: data, encoding: .utf8), !value.isEmpty {
                    cachedToken = value
                }
            } catch {
                throw LyricsProviderError.authenticationFailed
            }
        }
        if let cachedToken { return cachedToken }
        return try await issueSingleFlight(issue)
    }

    public func renew(replacing staleToken: String,
                      issue: @escaping @Sendable () async throws -> String) async throws -> String {
        if let cachedToken, cachedToken != staleToken { return cachedToken }
        cachedToken = nil
        return try await issueSingleFlight(issue)
    }

    public func clear() async throws {
        cachedToken = nil
        didLoadStoredToken = true
        issuance?.cancel()
        issuance = nil
        do {
            try await credentialStore.remove(service: Self.credentialService,
                                             account: Self.credentialAccount)
        } catch {
            throw LyricsProviderError.authenticationFailed
        }
    }

    private func issueSingleFlight(_ issue: @escaping @Sendable () async throws -> String) async throws -> String {
        let task: Task<String, Error>
        if let issuance {
            task = issuance
        } else {
            let created = Task { try await issue() }
            issuance = created
            task = created
        }
        do {
            let token = try await task.value
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issuance = nil
                throw LyricsProviderError.providerFormat
            }
            if cachedToken == nil {
                do {
                    try await credentialStore.set(Data(token.utf8), service: Self.credentialService,
                                                  account: Self.credentialAccount)
                } catch {
                    issuance = nil
                    throw LyricsProviderError.authenticationFailed
                }
                cachedToken = token
            }
            issuance = nil
            return cachedToken ?? token
        } catch let error as LyricsProviderError {
            issuance = nil
            throw error
        } catch is CancellationError {
            issuance = nil
            throw CancellationError()
        } catch {
            issuance = nil
            throw LyricsProviderError.transient
        }
    }
}
