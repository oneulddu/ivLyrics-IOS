import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public enum GenieLyricsParser {
    public static func parse(_ callbackText: String,
                             durationMs: Int64? = nil,
                             maxBytes: Int = 2_000_000) throws -> [ProviderLyricLine] {
        guard callbackText.utf8.count <= maxBytes else { throw LyricsProviderError.providerFormat }
        let trimmed = callbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.caseInsensitiveCompare("NOT FOUND LYRICS").isOrderedSame else {
            throw LyricsProviderError.miss
        }
        guard trimmed.range(of: #"^null\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw LyricsProviderError.providerFormat
        }
        let data = try ProviderParsingSupport.extractJSONPObject(callbackText: trimmed)
        let raw: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LyricsProviderError.providerFormat
            }
            raw = object
        } catch let error as LyricsProviderError { throw error }
        catch { throw LyricsProviderError.providerFormat }
        guard !raw.isEmpty else { throw LyricsProviderError.miss }

        var pairs: [(Int64, String)] = []
        var invalid = 0
        for (key, value) in raw {
            guard let timestamp = Int64(key), timestamp >= 0 else { invalid += 1; continue }
            guard let text = value as? String else { throw LyricsProviderError.providerFormat }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { invalid += 1; continue }
            pairs.append((timestamp, decodeEntities(cleaned)))
        }
        guard !pairs.isEmpty else { throw invalid > 0 ? LyricsProviderError.providerFormat : .miss }
        guard Double(pairs.count) / Double(raw.count) >= 0.5 else { throw LyricsProviderError.providerFormat }
        return try ProviderLRC.buildLines(from: pairs, durationMs: durationMs)
    }

    public static func plainText(from lines: [ProviderLyricLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private extension ComparisonResult {
    var isOrderedSame: Bool { self == .orderedSame }
}
