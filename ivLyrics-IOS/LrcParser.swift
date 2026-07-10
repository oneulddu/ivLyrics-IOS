import Foundation

enum LrcParser {
    private static let linePattern = #"^\[(\d+):(\d+)(?:[\.,](\d+))?\](.*)$"#

    static func parseSynced(_ lrc: String?, durationMs: Int64) -> [LyricsLine] {
        guard let lrc, !lrc.trimmed.isEmpty else {
            return []
        }

        var starts: [LyricsLine] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            guard let regex = try? NSRegularExpression(pattern: linePattern),
                  let match = regex.firstMatch(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)),
                  match.numberOfRanges >= 5 else {
                continue
            }
            let minutes = intGroup(match, 1, rawLine)
            let seconds = intGroup(match, 2, rawLine)
            let fraction = stringGroup(match, 3, rawLine)
            let text = stringGroup(match, 4, rawLine).trimmed
            let startMs = Int64(minutes * 60_000 + seconds * 1_000 + fractionToMillis(fraction))
            starts.append(LyricsLine(startTimeMs: startMs, endTimeMs: startMs, text: text))
        }

        var result: [LyricsLine] = []
        for index in starts.indices {
            let current = starts[index]
            let nextStart = index + 1 < starts.count ? starts[index + 1].startTimeMs : 0
            let fallbackEnd = durationMs > current.startTimeMs ? durationMs : current.startTimeMs + 4_000
            let end = nextStart > current.startTimeMs ? nextStart : fallbackEnd
            result.append(LyricsLine(startTimeMs: current.startTimeMs, endTimeMs: end, text: current.text))
        }
        return result
    }

    static func parsePlain(_ plainLyrics: String?) -> [LyricsLine] {
        guard let plainLyrics, !plainLyrics.trimmed.isEmpty else {
            return []
        }
        return plainLyrics.components(separatedBy: .newlines)
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .map { LyricsLine(startTimeMs: 0, endTimeMs: 0, text: $0) }
    }

    private static func stringGroup(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: source) else {
            return ""
        }
        return String(source[range])
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> Int {
        Int(stringGroup(match, index, source)) ?? 0
    }

    private static func fractionToMillis(_ fraction: String) -> Int {
        guard !fraction.isEmpty else { return 0 }
        let padded = String((fraction + "000").prefix(3))
        return Int(padded) ?? 0
    }
}
