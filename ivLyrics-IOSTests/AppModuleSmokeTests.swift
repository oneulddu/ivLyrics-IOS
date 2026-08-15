import XCTest
@testable import ivLyrics_IOS

final class AppModuleSmokeTests: XCTestCase {
    func testAppModuleLoadsThroughTestHost() {
        XCTAssertEqual(LyricsProviderAppContracts.providerDisplayName("unison"), "Unison")
        XCTAssertEqual(LyricsProviderAppContracts.providerDisplayName("paxsenix"), "Lyrically (Paxsenix)")
        XCTAssertEqual(LyricsProviderAppContracts.providerDisplayName("lyricsplus"), "LyricsPlus")
    }
}
