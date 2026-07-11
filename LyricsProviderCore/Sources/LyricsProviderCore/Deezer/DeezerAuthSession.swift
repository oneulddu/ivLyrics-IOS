import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public actor DeezerAuthSession {
    public static let credentialService = "deezer"
    public static let credentialAccount = "arl"

    private let credentialStore: any SensitiveCredentialStore
    private var cachedARL: String?
    private var didLoadARL = false
    private var jwt: String?
    private var jwtARL: String?
    private var exchangeTask: Task<String, Error>?

    public init(credentialStore: any SensitiveCredentialStore) {
        self.credentialStore = credentialStore
    }

    public func requireARL() async throws -> String {
        if !didLoadARL {
            didLoadARL = true
            do {
                if let data = try await credentialStore.get(service: Self.credentialService,
                                                            account: Self.credentialAccount),
                   let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    cachedARL = value
                }
            } catch {
                throw LyricsProviderError.authenticationFailed
            }
        }
        guard let cachedARL, !cachedARL.isEmpty else { throw LyricsProviderError.authenticationRequired }
        return cachedARL
    }

    public func setARL(_ value: String) async throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { try await removeARL(); return }
        do {
            try await credentialStore.set(Data(normalized.utf8), service: Self.credentialService,
                                          account: Self.credentialAccount)
        } catch {
            throw LyricsProviderError.authenticationFailed
        }
        cachedARL = normalized
        didLoadARL = true
        clearJWTState()
    }

    public func removeARL() async throws {
        do {
            try await credentialStore.remove(service: Self.credentialService,
                                             account: Self.credentialAccount)
        } catch {
            throw LyricsProviderError.authenticationFailed
        }
        cachedARL = nil
        didLoadARL = true
        clearJWTState()
    }

    func token(for arl: String,
               exchange: @escaping @Sendable () async throws -> String) async throws -> String {
        if jwtARL != arl { clearJWTState() }
        if let jwt { return jwt }
        return try await exchangeSingleFlight(arl: arl, exchange: exchange)
    }

    func refresh(replacing staleJWT: String, arl: String,
                 exchange: @escaping @Sendable () async throws -> String) async throws -> String {
        if jwtARL == arl, let jwt, jwt != staleJWT { return jwt }
        clearJWTState()
        return try await exchangeSingleFlight(arl: arl, exchange: exchange)
    }

    private func exchangeSingleFlight(arl: String,
                                      exchange: @escaping @Sendable () async throws -> String) async throws -> String {
        let task: Task<String, Error>
        if let exchangeTask {
            task = exchangeTask
        } else {
            let created = Task { try await exchange() }
            exchangeTask = created
            task = created
        }
        do {
            let value = try await task.value
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                exchangeTask = nil
                throw LyricsProviderError.authenticationFailed
            }
            if jwt == nil {
                jwt = value
                jwtARL = arl
            }
            exchangeTask = nil
            return jwt ?? value
        } catch is CancellationError {
            exchangeTask = nil
            throw CancellationError()
        } catch let error as LyricsProviderError {
            exchangeTask = nil
            throw error
        } catch {
            exchangeTask = nil
            throw LyricsProviderError.transient
        }
    }

    private func clearJWTState() {
        jwt = nil
        jwtARL = nil
        exchangeTask?.cancel()
        exchangeTask = nil
    }
}
