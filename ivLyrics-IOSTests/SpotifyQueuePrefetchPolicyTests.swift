import XCTest
@testable import ivLyrics_IOS

@MainActor
final class SpotifyQueuePrefetchPolicyTests: XCTestCase {
    func testSupplementPrefetchWaitsForFirstLanguageChoice() throws {
        let suiteName = "SpotifyQueuePrefetchPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ko", forKey: "ui_lang")
        defaults.set("ko", forKey: "output_lang")
        defaults.set(true, forKey: "translation_enabled")
        defaults.set(true, forKey: "pronunciation_enabled")
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.shouldPromptForFirstLanguage("ja"))
        XCTAssertFalse(
            AppViewModel.shouldPrefetchSpotifyQueueSupplements(
                settings: settings,
                sourceLang: "ja"
            )
        )

        settings.setLanguageRule(
            sourceLang: "ja",
            translationEnabled: false,
            pronunciationEnabled: false
        )

        XCTAssertFalse(settings.shouldPromptForFirstLanguage("ja"))
        XCTAssertTrue(
            AppViewModel.shouldPrefetchSpotifyQueueSupplements(
                settings: settings,
                sourceLang: "ja"
            )
        )
    }
}
