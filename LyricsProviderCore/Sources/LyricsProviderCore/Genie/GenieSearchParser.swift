import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public enum GenieSearchParser {
    public static func parse(_ html: String) throws -> [GenieTrack] {
        guard html.utf8.count <= 2_000_000 else { throw LyricsProviderError.providerFormat }
        let rowPattern = #"<tr\b(?=[^>]*\bclass\s*=\s*['\"][^'\"]*\blist\b[^'\"]*['\"])[^>]*>[\s\S]*?</tr\s*>"#
        let rows = matches(rowPattern, in: html)
        let hasSongListRegion = html.range(of: #"(?:class|id)\s*=\s*['\"][^'\"]*(?:song-list|music-list|songlist|musiclist)[^'\"]*['\"]"#,
                                               options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"<tr\b[^>]*\bclass\s*=\s*['\"][^'\"]*\blist\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
        guard hasSongListRegion else { throw LyricsProviderError.providerFormat }

        var seen = Set<String>()
        return rows.compactMap(parseRow).filter { seen.insert($0.id).inserted }
    }

    private static func parseRow(_ row: String) -> GenieTrack? {
        let id = firstCapture(#"\bsongid\s*=\s*['\"]([0-9]+)['\"]"#, in: row)
            ?? firstCapture(#"(?:fnViewSongInfo|playSong)\s*\(\s*['\"]([0-9]+)['\"]"#, in: row)
        guard let id else { return nil }
        let info = firstCapture(#"<td\b(?=[^>]*\bclass\s*=\s*['\"][^'\"]*\binfo\b[^'\"]*['\"])[^>]*>([\s\S]*?)</td\s*>"#, in: row) ?? row
        guard let title = anchorText(classToken: "title", in: info), !title.isEmpty,
              let artist = anchorText(classToken: "artist", in: info), !artist.isEmpty else { return nil }
        let durationText = firstCapture(#"<span\b(?=[^>]*\bclass\s*=\s*['\"][^'\"]*\bduration\b[^'\"]*['\"])[^>]*>([\s\S]*?)</span\s*>"#, in: info)
        return GenieTrack(id: id, title: title, artist: artist,
                          durationMs: durationText.flatMap { parseDuration(cleanText($0)) })
    }

    private static func anchorText(classToken: String, in value: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: classToken)
        let pattern = #"<a\b(?=[^>]*\bclass\s*=\s*['\"][^'\"]*\b"# + escaped + #"\b[^'\"]*['\"])([^>]*)>([\s\S]*?)</a\s*>"#
        guard let groups = captureGroups(pattern, in: value), groups.count == 2 else { return nil }
        if let attribute = firstCapture(#"\btitle\s*=\s*['\"]([^'\"]*)['\"]"#, in: groups[0]) {
            let cleaned = cleanText(attribute)
            if !cleaned.isEmpty { return cleaned }
        }
        return cleanText(removingIconSpans(groups[1]))
    }

    private static func removingIconSpans(_ value: String) -> String {
        value.replacingOccurrences(of: #"<span\b(?=[^>]*\bclass\s*=\s*['\"][^'\"]*\bicon(?:-[^'\"\s]+)?\b[^'\"]*['\"])[^>]*>[\s\S]*?</span\s*>"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func cleanText(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(stripped).split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func decodeEntities(_ value: String) -> String {
        var result = value
        let named = ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
                     "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, replacement) in named { result = result.replacingOccurrences(of: entity, with: replacement) }
        let regex = try! NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|([0-9]+));"#)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            let hex = Range(match.range(at: 1), in: result).map { String(result[$0]) }
            let decimal = Range(match.range(at: 2), in: result).map { String(result[$0]) }
            let scalar = hex.flatMap { UInt32($0, radix: 16) } ?? decimal.flatMap(UInt32.init)
            if let scalar, let unicode = UnicodeScalar(scalar), let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: String(unicode))
            }
        }
        return result
    }

    private static func parseDuration(_ value: String) -> Int64? {
        let raw = value.split(separator: ":")
        let parts = raw.compactMap { Int64($0) }
        guard parts.count == raw.count, parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2, parts[1] < 60 { return (parts[0] * 60 + parts[1]) * 1_000 }
        if parts.count == 3, parts[1] < 60, parts[2] < 60 {
            return (parts[0] * 3_600 + parts[1] * 60 + parts[2]) * 1_000
        }
        return nil
    }

    private static func matches(_ pattern: String, in value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        captureGroups(pattern, in: value)?.first
    }

    private static func captureGroups(_ pattern: String, in value: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) }
        }
    }
}
