import Foundation

struct UnisonResponseEnvelope: Decodable, Sendable {
    let success: Bool
    let data: UnisonLyricsData?
}

struct UnisonLyricsData: Decodable, Sendable {
    static let maximumDurationMs: Int64 = 86_400_000
    private static let maximumSongBytes = 512
    private static let maximumArtistBytes = 512
    private static let maximumAlbumBytes = 1_024
    private static let maximumFormatBytes = 32

    let lyrics: String
    let format: String
    let song: String
    let artist: String
    let album: String?
    let durationMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case lyrics, format, song, artist, album, duration, durationMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lyrics = try container.decode(String.self, forKey: .lyrics)
        format = try container.decode(String.self, forKey: .format)
        song = try container.decode(String.self, forKey: .song)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        try Self.validateLength(format, maximumBytes: Self.maximumFormatBytes, key: .format, container: container)
        try Self.validateLength(song, maximumBytes: Self.maximumSongBytes, key: .song, container: container)
        try Self.validateLength(artist, maximumBytes: Self.maximumArtistBytes, key: .artist, container: container)
        if let album {
            try Self.validateLength(album, maximumBytes: Self.maximumAlbumBytes, key: .album, container: container)
        }
        if let milliseconds = try container.decodeIfPresent(Int64.self, forKey: .durationMs) {
            guard (0...Self.maximumDurationMs).contains(milliseconds) else {
                throw DecodingError.dataCorruptedError(forKey: .durationMs, in: container,
                    debugDescription: "Duration is outside the supported range")
            }
            durationMs = milliseconds
        } else if container.contains(.duration), try !container.decodeNil(forKey: .duration) {
            let seconds: Double
            if let number = try? container.decode(Double.self, forKey: .duration) {
                seconds = number
            } else if let text = try? container.decode(String.self, forKey: .duration),
                      let number = Double(text) {
                seconds = number
            } else {
                throw DecodingError.dataCorruptedError(forKey: .duration, in: container,
                    debugDescription: "Duration is not numeric")
            }
            let milliseconds = seconds * 1_000
            guard seconds.isFinite, milliseconds.isFinite, milliseconds >= 0,
                  milliseconds <= Double(Self.maximumDurationMs) else {
                throw DecodingError.dataCorruptedError(forKey: .duration, in: container,
                    debugDescription: "Duration is outside the supported range")
            }
            durationMs = Int64(milliseconds.rounded())
        } else {
            durationMs = nil
        }
    }

    private static func validateLength(
        _ value: String,
        maximumBytes: Int,
        key: CodingKeys,
        container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard value.utf8.count <= maximumBytes else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container,
                debugDescription: "Metadata field is too long")
        }
    }
}

struct UnisonParsedLyrics: Sendable {
    let lines: [ProviderLyricLine]
    let timing: LyricsTiming
}
