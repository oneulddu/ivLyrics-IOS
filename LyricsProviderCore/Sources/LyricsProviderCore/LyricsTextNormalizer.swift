import Foundation

public enum LyricsTextNormalizer {
    public static func comparableLyricsLines(_ text: String?, stripTimestamps: Bool,
                                             normalizeParentheticalLines: Bool = false) -> [String] {
        guard let text, !trim(text).isEmpty else { return [] }
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = stripTimestamps ? stripLeadingLrcTimestamp(rawLine) : trim(rawLine)
            line = trim(line.precomposedStringWithCanonicalMapping)
            if line.isEmpty || line.range(of: #"^\s*\[(?:ar|al|ti|au|length|by|offset|re|ve):[^\]]*\]\s*$"#, options: .regularExpression) != nil {
                continue
            }
            lines.append(line)
        }
        if normalizeParentheticalLines {
            return normalizeStandaloneParentheticalBlocks(lines)
                .map { trim($0.precomposedStringWithCanonicalMapping) }.filter { !$0.isEmpty }
        }
        return lines
    }

    public static func lineCharCounts(_ lines: [String]) -> [Int] {
        lines.map { $0.precomposedStringWithCanonicalMapping.unicodeScalars.count }
    }

    public static func lyricsFingerprint(_ text: String) -> String {
        var hash: UInt64 = 2_166_136_261
        let scalars = text.precomposedStringWithCanonicalMapping.unicodeScalars
        for scalar in scalars {
            hash ^= UInt64(scalar.value)
            hash = (hash * 16_777_619) & 0xffff_ffff
        }
        return "lrclib-\(String(hash, radix: 36))-\(String(scalars.count, radix: 36))"
    }

    public static func joinLinesForFingerprint(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    public static func hasOriginalLyricsScript(_ text: String) -> Bool {
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let value = scalar.value
            if (0x3040...0x30ff).contains(value) || (0x3400...0x4dbf).contains(value)
                || (0x4e00...0x9fff).contains(value) || (0xf900...0xfaff).contains(value)
                || (0x1100...0x11ff).contains(value) || (0x3130...0x318f).contains(value)
                || (0xac00...0xd7af).contains(value) { return true }
        }
        return false
    }

    public static func stripLrcTimestamps(_ text: String?) -> String {
        trim((text ?? "").replacingOccurrences(of: #"(?m)^\[\d+:\d+(?:[.,]\d+)?\]\s*"#,
                                               with: "", options: .regularExpression))
    }

    public static func stripLeadingLrcTimestamp(_ text: String) -> String {
        text.replacingOccurrences(of: #"^\[\d+:\d+(?:[.,]\d+)?\]\s*"#,
                                  with: "", options: .regularExpression)
    }

    private static func normalizeStandaloneParentheticalBlocks(_ lines: [String]) -> [String] {
        var normalized = lines.map(stripStandaloneParentheticalLine)
        for index in normalized.indices {
            let value = trim(normalized[index].precomposedStringWithCanonicalMapping)
            guard let first = value.unicodeScalars.first else { continue }
            let close: UnicodeScalar? = first == "(" ? ")" : (first == "（" ? "）" : nil)
            guard let close, !value.unicodeScalars.contains(close) else { continue }
            guard let closeIndex = normalized.indices.first(where: {
                $0 > index && trim(normalized[$0]).unicodeScalars.last == close
            }) else { continue }
            normalized[index] = removeFirstScalar(normalized[index], matching: first)
            normalized[closeIndex] = removeLastScalar(normalized[closeIndex], matching: close)
        }
        return normalized
    }

    private static func stripStandaloneParentheticalLine(_ text: String) -> String {
        var value = trim(text.precomposedStringWithCanonicalMapping)
        while true {
            let chars = Array(value.unicodeScalars)
            guard chars.count >= 2 else { return value }
            let close: UnicodeScalar? = chars[0] == "(" ? ")" : (chars[0] == "（" ? "）" : nil)
            guard close == chars.last else { return value }
            if chars.count <= 2 { return "" }
            value = trim(String(String.UnicodeScalarView(chars[1..<(chars.count - 1)])))
        }
    }

    private static func removeFirstScalar(_ text: String, matching scalar: UnicodeScalar) -> String {
        var scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        if let index = scalars.firstIndex(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
           scalars[index] == scalar { scalars.remove(at: index) }
        return trim(String(String.UnicodeScalarView(scalars)))
    }

    private static func removeLastScalar(_ text: String, matching scalar: UnicodeScalar) -> String {
        var scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        if let index = scalars.lastIndex(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
           scalars[index] == scalar { scalars.remove(at: index) }
        return trim(String(String.UnicodeScalarView(scalars)))
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
