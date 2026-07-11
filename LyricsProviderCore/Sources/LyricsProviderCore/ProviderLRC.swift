import Foundation

public enum ProviderLRC {
    private static let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d+):(\d+)(?:[.,](\d+))?\](.*)$"#)

    public static func parse(_ text: String, durationMs: Int64? = nil,
                             minimumValidRatio: Double = 0.35) throws -> [ProviderLyricLine] {
        let sourceLines = text.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !sourceLines.isEmpty else { throw LyricsProviderError.miss }
        var pairs: [(Int64, String)] = []
        for line in sourceLines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = lineRegex.firstMatch(in: line, range: range), match.numberOfRanges == 5 else { continue }
            let minutes = intGroup(match, 1, line), seconds = intGroup(match, 2, line)
            guard seconds < 60 else { continue }
            let fraction = stringGroup(match, 3, line)
            let millis = Int64(minutes * 60_000 + seconds * 1_000 + fractionMillis(fraction))
            pairs.append((millis, stringGroup(match, 4, line).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard Double(pairs.count) / Double(sourceLines.count) >= minimumValidRatio else {
            throw LyricsProviderError.providerFormat
        }
        return try buildLines(from: pairs, durationMs: durationMs)
    }

    public static func buildLines(from pairs: [(Int64, String)], durationMs: Int64? = nil,
                                  severeRegressionMs: Int64 = 2_000,
                                  minimumValidRatio: Double = 0.5) throws -> [ProviderLyricLine] {
        guard !pairs.isEmpty else { throw LyricsProviderError.miss }
        var sanitized: [(Int64, String)] = [], highWater: Int64 = -1
        for (time, rawText) in pairs {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard time >= 0 else { continue }
            if highWater >= 0, time + severeRegressionMs < highWater { continue }
            highWater = max(highWater, time)
            sanitized.append((time, text))
        }
        guard Double(sanitized.count) / Double(pairs.count) >= minimumValidRatio else {
            throw LyricsProviderError.providerFormat
        }
        sanitized.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return sanitized.enumerated().map { index, pair in
            let next = index + 1 < sanitized.count ? sanitized[index + 1].0 : nil
            let fallback = durationMs.flatMap { $0 > pair.0 ? $0 : nil } ?? pair.0 + 4_000
            let end = next.flatMap { $0 > pair.0 ? $0 : nil } ?? fallback
            return ProviderLyricLine(startMs: pair.0, endMs: end, text: pair.1)
        }
    }

    public static func splitPlainText(_ text: String) -> [ProviderLyricLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ProviderLyricLine(startMs: 0, endMs: nil, text: $0) }
    }

    private static func stringGroup(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }
        return String(text[range])
    }
    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> Int {
        Int(stringGroup(match, index, text)) ?? 0
    }
    private static func fractionMillis(_ fraction: String) -> Int {
        guard !fraction.isEmpty else { return 0 }
        return Int(String((fraction + "000").prefix(3))) ?? 0
    }
}
