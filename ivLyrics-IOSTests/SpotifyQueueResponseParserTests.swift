import XCTest
@testable import ivLyrics_IOS

final class SpotifyQueueResponseParserTests: XCTestCase {
    func testNextTrackMapsImmediateTrackAndChoosesWidestArtwork() throws {
        let data = try XCTUnwrap(
            """
            {
              "queue": [
                {
                  "type": "track",
                  "id": "1234567890123456789012",
                  "name": "Next Song",
                  "artists": [{"name": "First Artist"}, {"name": "Second Artist"}],
                  "album": {
                    "name": "Next Album",
                    "images": [
                      {"url": "https://example.com/small.jpg", "width": 64},
                      {"url": "https://example.com/large.jpg", "width": 640}
                    ]
                  },
                  "duration_ms": 245000,
                  "external_ids": {"isrc": "USRC17607839"}
                }
              ]
            }
            """.data(using: .utf8)
        )

        let track = try XCTUnwrap(SpotifyQueueResponseParser.nextTrack(from: data))

        XCTAssertEqual(track.title, "Next Song")
        XCTAssertEqual(track.artist, "First Artist, Second Artist")
        XCTAssertEqual(track.album, "Next Album")
        XCTAssertEqual(track.trackId, "1234567890123456789012")
        XCTAssertEqual(track.isrc, "USRC17607839")
        XCTAssertEqual(track.durationMs, 245000)
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://example.com/large.jpg")
        XCTAssertFalse(track.playing)
        XCTAssertEqual(track.positionMs, 0)
    }

    func testEmptyQueueReturnsNil() throws {
        let data = try XCTUnwrap(#"{"queue":[]}"#.data(using: .utf8))

        XCTAssertNil(SpotifyQueueResponseParser.nextTrack(from: data))
    }

    func testLeadingEpisodeDoesNotSkipAheadToLaterTrack() throws {
        let data = try XCTUnwrap(
            """
            {
              "queue": [
                {"type": "episode", "id": "episode-id", "name": "Podcast Episode"},
                {
                  "type": "track",
                  "id": "1234567890123456789012",
                  "name": "Later Song",
                  "artists": [{"name": "Artist"}]
                }
              ]
            }
            """.data(using: .utf8)
        )

        XCTAssertNil(SpotifyQueueResponseParser.nextTrack(from: data))
    }

    func testMalformedImmediateItemReturnsNil() throws {
        let data = try XCTUnwrap(#"{"queue":[{"name":"Missing Type"}]}"#.data(using: .utf8))

        XCTAssertNil(SpotifyQueueResponseParser.nextTrack(from: data))
    }

    func testSpotifyDJSegmentReturnsNil() throws {
        let data = try XCTUnwrap(
            """
            {
              "queue": [
                {
                  "type": "track",
                  "id": "1234567890123456789012",
                  "name": "Up Next",
                  "artists": [{"name": "DJ X"}]
                }
              ]
            }
            """.data(using: .utf8)
        )

        XCTAssertNil(SpotifyQueueResponseParser.nextTrack(from: data))
    }

    func testHTTPResponsePolicyRefreshesUnauthorizedAndLatchesForbidden() {
        XCTAssertEqual(SpotifyQueueHTTPResponsePolicy.action(for: 200), .parseBody)
        XCTAssertEqual(SpotifyQueueHTTPResponsePolicy.action(for: 204), .noContent)
        XCTAssertEqual(SpotifyQueueHTTPResponsePolicy.action(for: 401), .invalidateAccessToken)
        XCTAssertEqual(SpotifyQueueHTTPResponsePolicy.action(for: 403), .disableForAuthorization)
        XCTAssertEqual(SpotifyQueueHTTPResponsePolicy.action(for: 429), .ignore)
    }
}
