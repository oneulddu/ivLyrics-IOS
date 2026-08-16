import XCTest
@testable import ivLyrics_IOS

final class SpotifyWebAPIAuthorizationCoordinatorTests: XCTestCase {
    func testAppRemoteSuccessWithoutWebAPIRequestsSingleAuthorization() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: false),
            .authorize
        )
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: false),
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
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: false),
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
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertFalse(coordinator.retryAfterInvalidStoredAuthorization())
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: false),
            .authorize
        )
    }

    func testInvalidStoredAuthorizationPreservesQueuedPollingFallback() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: true),
            .waitForInFlightAuthorization
        )
        let requiresPollingFallback = coordinator.retryAfterInvalidStoredAuthorization()
        XCTAssertTrue(requiresPollingFallback)
        XCTAssertEqual(
            coordinator.request(
                storedAuthorizationAvailable: false,
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
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertEqual(
            coordinator.completeTemporaryValidationFailure(appRemoteConnected: true),
            .keepAppRemote
        )
        XCTAssertFalse(coordinator.authorizationSuppressed)
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
    }

    func testQueueAuthorizationRecoveryRevalidatesStoredAuthorization() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: false),
            .validateExistingAuthorization
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: true, appRemoteConnected: true),
            .keepAppRemote
        )
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: true, requiresPollingFallback: false),
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

    func testUnexpiredAccessTokenRequiresRefreshWhenSpotifyRejectsIt() {
        XCTAssertEqual(
            SpotifyStoredAccessTokenValidationPolicy.action(statusCode: 204),
            .reusable
        )
        XCTAssertEqual(
            SpotifyStoredAccessTokenValidationPolicy.action(statusCode: 401),
            .refreshRequired
        )
    }

    func testAccessTokenValidationFailurePreservesStoredAuthorizationForRetry() {
        XCTAssertEqual(
            SpotifyStoredAccessTokenValidationPolicy.action(statusCode: 429),
            .temporarilyUnavailable
        )
        XCTAssertEqual(
            SpotifyStoredAccessTokenValidationPolicy.action(statusCode: 500),
            .temporarilyUnavailable
        )
    }

    func testAuthorizationFailureKeepsAppRemoteAndSuppressesReconnectPrompt() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: false),
            .authorize
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: false, appRemoteConnected: true),
            .keepAppRemote
        )
        XCTAssertTrue(coordinator.authorizationSuppressed)
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: false),
            .suppressedAfterFailure
        )

        coordinator.resetForUserInitiatedConnection()
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: false),
            .authorize
        )
    }

    func testFallbackQueuedDuringAuthorizationStartsPollingOnlyAfterAppRemoteDrops() {
        var coordinator = SpotifyWebAPIAuthorizationCoordinator()

        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: false),
            .authorize
        )
        XCTAssertEqual(
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: true),
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
            coordinator.request(storedAuthorizationAvailable: false, requiresPollingFallback: true),
            .authorize
        )
        XCTAssertEqual(
            coordinator.complete(succeeded: false, appRemoteConnected: false),
            .fallbackUnavailable
        )
        XCTAssertFalse(coordinator.authorizationInFlight)
    }
}
