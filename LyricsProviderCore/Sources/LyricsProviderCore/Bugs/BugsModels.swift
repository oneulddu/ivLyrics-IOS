import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public struct BugsTrack: Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let durationMs: Int64?

    public init(id: String, title: String, artist: String, durationMs: Int64? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.durationMs = durationMs
    }
}

struct BugsSearchResponse: Decodable {
    let list: [BugsSearchTrack]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = try container.decodeIfPresent([BugsSearchTrack].self, forKey: .list) ?? []
    }

    private enum CodingKeys: String, CodingKey { case list }
}

struct BugsSearchTrack: Decodable {
    let trackID: String
    let trackTitle: String
    let artists: [BugsArtist]
    let length: String?

    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case trackTitle = "track_title"
        case artists
        case length = "len"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? container.decode(String.self, forKey: .trackID) {
            trackID = id
        } else if let id = try? container.decode(Int64.self, forKey: .trackID) {
            trackID = String(id)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .trackID, in: container,
                                                   debugDescription: "Invalid track identifier")
        }
        trackTitle = try container.decode(String.self, forKey: .trackTitle)
        artists = try container.decodeIfPresent([BugsArtist].self, forKey: .artists) ?? []
        length = try container.decodeIfPresent(String.self, forKey: .length)
    }
}

struct BugsArtist: Decodable {
    let name: String
    private enum CodingKeys: String, CodingKey { case name = "artist_nm" }
}

struct BugsLyricsResponse: Decodable {
    let lyrics: String?
}
