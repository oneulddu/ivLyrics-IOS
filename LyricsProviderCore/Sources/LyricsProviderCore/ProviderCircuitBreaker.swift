import Foundation

public actor ProviderCircuitBreaker {
    public enum Permission: Sendable, Equatable {
        case allowed
        case probe
        case denied(retryAt: Date)
    }

    public struct State: Sendable, Equatable {
        public let consecutiveFailures: Int
        public let openedAt: Date?
        public let retryAt: Date?
        public let probeInFlight: Bool
    }

    private struct MutableState {
        var consecutiveFailures = 0
        var openedAt: Date?
        var retryAt: Date?
        var probeInFlight = false
    }

    private let now: @Sendable () -> Date
    private let formatFailureThreshold: Int
    private let ordinaryFailureThreshold: Int
    private let baseCooldown: TimeInterval
    private var states: [LyricsProviderID: MutableState] = [:]

    public init(formatFailureThreshold: Int = 2, ordinaryFailureThreshold: Int = 3,
                baseCooldown: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.formatFailureThreshold = max(1, formatFailureThreshold)
        self.ordinaryFailureThreshold = max(1, ordinaryFailureThreshold)
        self.baseCooldown = max(0, baseCooldown)
        self.now = now
    }

    public func permission(for provider: LyricsProviderID) -> Permission {
        var state = states[provider] ?? MutableState()
        guard let retryAt = state.retryAt else { return .allowed }
        guard now() >= retryAt else { return .denied(retryAt: retryAt) }
        guard !state.probeInFlight else { return .denied(retryAt: retryAt) }
        state.probeInFlight = true
        states[provider] = state
        return .probe
    }

    public func recordSuccess(for provider: LyricsProviderID) {
        states[provider] = MutableState()
    }

    public func record(_ error: LyricsProviderError, for provider: LyricsProviderID) {
        var state = states[provider] ?? MutableState()
        state.probeInFlight = false
        guard countsAsFailure(error) else {
            states[provider] = state
            return
        }
        state.consecutiveFailures += 1
        let threshold = error == .providerFormat ? formatFailureThreshold : ordinaryFailureThreshold
        guard state.consecutiveFailures >= threshold else {
            states[provider] = state
            return
        }
        let opened = now()
        let retryAfter: TimeInterval
        if case let .rateLimited(value) = error, let value { retryAfter = max(baseCooldown, value) }
        else { retryAfter = baseCooldown * pow(2, Double(max(0, state.consecutiveFailures - threshold))) }
        state.openedAt = state.openedAt ?? opened
        state.retryAt = opened.addingTimeInterval(retryAfter)
        states[provider] = state
    }

    public func cancelProbe(for provider: LyricsProviderID) {
        states[provider]?.probeInFlight = false
    }

    public func state(for provider: LyricsProviderID) -> State {
        let state = states[provider] ?? MutableState()
        return State(consecutiveFailures: state.consecutiveFailures, openedAt: state.openedAt,
                     retryAt: state.retryAt, probeInFlight: state.probeInFlight)
    }

    private func countsAsFailure(_ error: LyricsProviderError) -> Bool {
        switch error {
        case .miss, .authenticationRequired, .policyDisabled, .cancelled: return false
        default: return true
        }
    }
}
