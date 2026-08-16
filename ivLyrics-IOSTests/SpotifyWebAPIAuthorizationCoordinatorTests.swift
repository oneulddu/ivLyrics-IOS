import XCTest
@testable import ivLyrics_IOS

final class SpotifyWebAPIAuthorizationCoordinatorTests: XCTestCase {
    func testAppRemoteSuccessWithoutWebAPIRequestsSingleAuthorization() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: false),
            .authorize
        )
        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: false),
            .waitForInFlightAuthorization
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: true, appRemoteConnected: true),
            .keepAppRemote
        )
        XCTAssertFalse(coordinator.authorizationInFlight)
        XCTAssertFalse(coordinator.authorizationSuppressed)
    }

    func testExistingWebAPIAuthorizationKeepsAppRemoteWithoutNewAuthorization() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: true, appRemoteConnected: true),
            .keepAppRemote
        )
        XCTAssertFalse(coordinator.authorizationInFlight)
    }

    func testInvalidStoredAuthorizationRetriesInteractiveAuthorization() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertFalse(coordinator.retryAfterInvalidStoredAuthorization())
        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: false),
            .authorize
        )
    }

    func testInvalidStoredAuthorizationPreservesQueuedPollingFallback() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertEqual(
            coordinator.request(webAPIConnected: true, requiresPollingFallback: true),
            .waitForInFlightAuthorization
        )
        let requiresPollingFallback = coordinator.retryAfterInvalidStoredAuthorization()
        XCTAssertTrue(requiresPollingFallback)
        XCTAssertEqual(
            coordinator.request(
                webAPIConnected: false,
                requiresPollingFallback: requiresPollingFallback
            ),
            .authorize
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: true, appRemoteConnected: false),
            .startWebAPIPolling
        )
    }

    func testTemporaryValidationFailureRemainsRetryable() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertEqual(
            coordinator.completeTemporaryValidationFailure(appRemoteConnected: true),
            .keepAppRemote
        )
        XCTAssertFalse(coordinator.authorizationSuppressed)
        XCTAssertEqual(
            coordinator.request(webAPIConnected: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
    }

    func testRefreshFailurePolicyDiscardsOnlyInvalidGrant() {
        XCTAssertEqual(
            SpotifyStoredAuthorizationRefreshFailurePolicy.action(
                statusCode: 400,
                message: #"{"error":"invalid_grant"}"#
            ),
            .discardAndReauthorize
        )
        XCTAssertEqual(
            SpotifyStoredAuthorizationRefreshFailurePolicy.action(
                statusCode: 500,
                message: "server unavailable"
            ),
            .preserveAndRetryLater
        )
        XCTAssertEqual(
            SpotifyStoredAuthorizationRefreshFailurePolicy.action(
                statusCode: nil,
                message: "network unavailable"
            ),
            .preserveAndRetryLater
        )
    }

    func testAuthorizationFailureKeepsAppRemoteAndSuppressesReconnectPrompt() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: false),
            .authorize
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: false, appRemoteConnected: true),
            .keepAppRemote
        )
        XCTAssertTrue(coordinator.authorizationSuppressed)
        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: false),
            .suppressedAfterFailure
        )

        coordinator.resetForUserInitiatedConnection()
        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: false),
            .authorize
        )
    }

    func testFallbackQueuedDuringAuthorizationStartsPollingOnlyAfterAppRemoteDrops() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: false),
            .authorize
        )
        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: true),
            .waitForInFlightAuthorization
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: true, appRemoteConnected: false),
            .startWebAPIPolling
        )
    }

    func testFallbackFailureWithoutAppRemoteEndsInSafeUnavailableState() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(webAPIConnected: false, requiresPollingFallback: true),
            .authorize
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: false, appRemoteConnected: false),
            .fallbackUnavailable
        )
        XCTAssertFalse(coordinator.authorizationInFlight)
    }
}
