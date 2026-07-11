import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public struct GenieTrack: Hashable, Sendable {
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
