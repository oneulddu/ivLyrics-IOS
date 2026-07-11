import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public enum BugsParser {
    public static func parseSearch(_ data: Data) throws -> [BugsTrack] {
        let payload: BugsSearchResponse
        do { payload = try JSONDecoder().decode(BugsSearchResponse.self, from: data) }
        catch { throw LyricsProviderError.providerFormat }

        return payload.list.compactMap { item in
            let title = item.trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = item.artists.map(\.name)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            guard !item.trackID.isEmpty, !title.isEmpty, !artist.isEmpty else { return nil }
            return BugsTrack(id: item.trackID, title: title, artist: artist,
                             durationMs: parseDuration(item.length))
        }
    }

    public static func parseSyncedLyrics(_ value: String,
                                         durationMs: Int64? = nil) throws -> [ProviderLyricLine] {
        let entries = value.split(separator: "＃", omittingEmptySubsequences: true)
        guard !entries.isEmpty else { throw LyricsProviderError.miss }
        var pairs: [(Int64, String)] = []

        for rawEntry in entries {
            let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = entry.firstIndex(of: "|") else { continue }
            let secondsText = entry[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let text = entry[entry.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let seconds = Double(secondsText), seconds.isFinite, seconds >= 0,
                  !text.isEmpty, seconds <= Double(Int64.max) / 1_000 else { continue }
            pairs.append((Int64((seconds * 1_000).rounded()), text))
        }

        guard Double(pairs.count) / Double(entries.count) >= 0.5 else {
            throw LyricsProviderError.providerFormat
        }
        var highWater: Int64 = -1
        for pair in pairs {
            if highWater >= 0, pair.0 + 2_000 < highWater {
                throw LyricsProviderError.providerFormat
            }
            highWater = max(highWater, pair.0)
        }
        return try ProviderLRC.buildLines(from: pairs, durationMs: durationMs)
    }

    public static func normalizePlainLyrics(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw LyricsProviderError.miss }
        return normalized
    }

    static func parseLyricsBody(_ data: Data) throws -> String {
        let payload: BugsLyricsResponse
        do { payload = try JSONDecoder().decode(BugsLyricsResponse.self, from: data) }
        catch { throw LyricsProviderError.providerFormat }
        guard let lyrics = payload.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lyrics.isEmpty else { throw LyricsProviderError.miss }
        return lyrics
    }

    private static func parseDuration(_ value: String?) -> Int64? {
        guard let value else { return nil }
        let components = value.split(separator: ":").compactMap { Int64($0) }
        guard components.count == value.split(separator: ":").count,
              (components.count == 2 || components.count == 3),
              components.allSatisfy({ $0 >= 0 }) else { return nil }
        if components.count == 2 {
            guard components[1] < 60 else { return nil }
            return (components[0] * 60 + components[1]) * 1_000
        }
        guard components[1] < 60, components[2] < 60 else { return nil }
        return (components[0] * 3_600 + components[1] * 60 + components[2]) * 1_000
    }
}
