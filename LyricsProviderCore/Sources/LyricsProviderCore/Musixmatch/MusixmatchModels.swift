import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
struct MusixmatchTrack: Decodable, Sendable {
    let trackID: Int64
    let trackName: String
    let trackLength: Int64
    let artistName: String
    let hasLyrics: Bool
    let hasSubtitles: Bool
    let hasRichsync: Bool

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case trackName = "track_name"
        case trackLength = "track_length"
        case artistName = "artist_name"
        case hasLyrics = "has_lyrics"
        case hasSubtitles = "has_subtitles"
        case hasRichsync = "has_richsync"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try values.decode(Int64.self, forKey: .trackID)
        trackName = try values.decode(String.self, forKey: .trackName)
        trackLength = try values.decodeIfPresent(Int64.self, forKey: .trackLength) ?? 0
        artistName = try values.decode(String.self, forKey: .artistName)
        hasLyrics = try values.decodeBoolishIfPresent(forKey: .hasLyrics)
        hasSubtitles = try values.decodeBoolishIfPresent(forKey: .hasSubtitles)
        hasRichsync = try values.decodeBoolishIfPresent(forKey: .hasRichsync)
    }
}

private extension KeyedDecodingContainer {
    func decodeBoolishIfPresent(forKey key: Key) throws -> Bool {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        return false
    }
}

struct MusixmatchTokenBody: Decodable { let userToken: String; enum CodingKeys: String, CodingKey { case userToken = "user_token" } }
struct MusixmatchTrackBody: Decodable { let track: MusixmatchTrack }
struct MusixmatchTrackListBody: Decodable { let trackList: [Item]; enum CodingKeys: String, CodingKey { case trackList = "track_list" }; struct Item: Decodable { let track: MusixmatchTrack } }
struct MusixmatchSubtitleBody: Decodable { let subtitle: Subtitle; struct Subtitle: Decodable { let subtitleBody: String; enum CodingKeys: String, CodingKey { case subtitleBody = "subtitle_body" } } }
struct MusixmatchLyricsBody: Decodable {
    let lyrics: Lyrics
    struct Lyrics: Decodable {
        let lyricsBody: String
        let lyricsCopyright: String?
        enum CodingKeys: String, CodingKey { case lyricsBody = "lyrics_body"; case lyricsCopyright = "lyrics_copyright" }
    }
}
