import XCTest
@testable import ivLyrics_IOS

final class AppModuleSmokeTests: XCTestCase {
    func testAppModuleLoadsThroughTestHost() {
        XCTAssertEqual(LyricsProviderAppContracts.providerDisplayName("unison"), "Unison")
    }
}
