import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
struct DeezerSearchResponse: Decodable { let data: [DeezerTrack] }
struct DeezerTrack: Decodable, Sendable {
    let id: Int64
    let title: String
    let duration: Int64
    let artist: Artist
    struct Artist: Decodable, Sendable { let name: String }
}

struct DeezerAuthResponse: Decodable { let jwt: String? }
struct DeezerGraphQLResponse: Decodable {
    let data: DataPayload?
    let errors: [GraphQLError]?
    struct DataPayload: Decodable { let track: Track? }
    struct Track: Decodable { let lyrics: DeezerLyrics? }
    struct GraphQLError: Decodable { let message: String }
}

struct DeezerLyrics: Decodable, Sendable {
    let text: String?
    let copyright: String?
    let synchronizedLines: [SynchronizedLine]?
    let synchronizedWordByWordLines: [WordLine]?

    struct SynchronizedLine: Decodable, Sendable {
        let lrcTimestamp: String?
        let line: String
        let milliseconds: Int64
        let duration: Int64?
    }
    struct WordLine: Decodable, Sendable {
        let start: Int64?
        let end: Int64?
        let words: [Word]
    }
    struct Word: Decodable, Sendable {
        let start: Int64
        let end: Int64?
        let word: String
    }
}
