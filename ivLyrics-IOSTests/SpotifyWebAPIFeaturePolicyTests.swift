import XCTest
@testable import ivLyrics_IOS

@MainActor
final class SpotifyWebAPIFeaturePolicyTests: XCTestCase {
    func testWebAPIDefaultsOffAndPersistsExplicitOptIn() throws {
        let suiteName = "SpotifyWebAPIFeaturePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings: AppSettings? = AppSettings(defaults: defaults)
        XCTAssertFalse(try XCTUnwrap(settings).spotifyWebAPIEnabled)

        settings?.spotifyWebAPIEnabled = true
        settings = nil

        XCTAssertTrue(AppSettings(defaults: defaults).spotifyWebAPIEnabled)
    }

    func testDisabledFeatureRejectsAuthorizationAndQueueUse() {
        XCTAssertFalse(SpotifyWebAPIFeaturePolicy.allowsAuthorization(enabled: false))
        XCTAssertFalse(
            SpotifyWebAPIFeaturePolicy.canUseUserToken(enabled: false, connected: true)
        )
        XCTAssertFalse(
            SpotifyWebAPIFeaturePolicy.shouldPrefetchQueue(enabled: false, connected: true)
        )
    }

    func testEnabledFeatureStillRequiresConnectedUserAuthorization() {
        XCTAssertTrue(SpotifyWebAPIFeaturePolicy.allowsAuthorization(enabled: true))
        XCTAssertFalse(
            SpotifyWebAPIFeaturePolicy.canUseUserToken(enabled: true, connected: false)
        )
        XCTAssertTrue(
            SpotifyWebAPIFeaturePolicy.shouldPrefetchQueue(enabled: true, connected: true)
        )
    }

    func testMetadataTokenRecoveryOnlyRetriesUnauthorizedResponses() {
        XCTAssertTrue(SpotifyMetadataTokenRecoveryPolicy.shouldRecover(statusCode: 401))
        XCTAssertFalse(SpotifyMetadataTokenRecoveryPolicy.shouldRecover(statusCode: 403))
        XCTAssertFalse(SpotifyMetadataTokenRecoveryPolicy.shouldRecover(statusCode: 429))
    }

    func testQueuePrefetchStopsWhenFeatureTurnsOffInFlight() {
        XCTAssertTrue(
            SpotifyWebAPIFeaturePolicy.shouldContinueQueuePrefetch(
                enabled: true,
                isCancelled: false,
                sourceMatches: true
            )
        )
        XCTAssertFalse(
            SpotifyWebAPIFeaturePolicy.shouldContinueQueuePrefetch(
                enabled: false,
                isCancelled: false,
                sourceMatches: true
            )
        )
    }
}
