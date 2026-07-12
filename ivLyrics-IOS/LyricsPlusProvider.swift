import Foundation

enum LyricsPlusProvider {
    static let projectURL = "https://github.com/ibratabian17/lyricsplus"

    private static let encodedBaseURLs = [
        "YUhSMGNITTZMeTlzZVhKcFkzTndiSFZ6TG5CeWFtdDBiR0V1YlhrdWFXUT0=",
        "YUhSMGNITTZMeTlzZVhKcFkzTXVaMlZsYTJWa0xuZDBaZz09"
    ]
    private static let requestTimeout: TimeInterval = 12
    private static let splitTriggerWidth = 22.0
    private static let splitHardWidth = 26.0
    private static let splitMinimumWidth = 6.0
    private static let splitMinimumDurationMs: Int64 = 500
    private static let splitMaximumSegments = 4
    private static let parallelMaximumSourceLines = 4
    private static let parallelMinimumOverlapMs: Int64 = 30
    private static let parallelMaximumSegmentDelayMs: Int64 = 16
    private static let endpointRotation = EndpointRotation()
    private static let speakerPalette: [(String, String)] = [
        ("#a8ccff", "MALE 1"),
        ("#ffb8c7", "FEMALE 1"),
        ("#e4d8ff", "DUET 1"),
        ("#9ae8d4", "MALE 2"),
        ("#ffd6b3", "FEMALE 2"),
        ("#d6e4ff", "DUET 2"),
        ("#bfe8ff", "MALE 3"),
        ("#f6c8ff", "FEMALE 3"),
        ("#ffddf2", "DUET 3")
    ]

    struct FetchOutcome: Sendable {
        var karaoke: [LyricsLine]?
        var synced: [LyricsLine]?
        var plain: [LyricsLine]?
        var sourceType: String
        var logs: [String]
    }

    private struct RawLine: Sendable {
        var sourceIndex: Int
        var key: String
        var singer: String
        var line: LyricsLine
        var hasTiming: Bool
        var hasWordTiming: Bool
    }

    private struct RawSyllable: Sendable {
        var value: LyricsLine.Syllable
        var isBackground: Bool
    }

    private struct SpeakerPresentation: Sendable {
        var speaker: String
        var color: String
        var fallback: String
    }

    private struct VocalLane: Sendable {
        var singer: String
        var lines: [RawLine]
        var endTimeMs: Int64

        var durationMs: Int64 {
            lines.reduce(0) { total, raw in
                total + max(0, raw.line.endTimeMs - raw.line.startTimeMs)
            }
        }

        var startTimeMs: Int64 {
            lines.map(\.line.startTimeMs).min() ?? 0
        }

        var minimumSourceIndex: Int {
            lines.map(\.sourceIndex).min() ?? 0
        }
    }

    private struct ParallelSplit: Sendable {
        var left: [RawLine]
        var right: [RawLine]
        var leftEndTimeMs: Int64
        var nextStartTimeMs: Int64
        var leftKeyCount: Int
        var maximumDelayMs: Int64
        var distanceMs: Int64
    }

    private actor EndpointRotation {
        private var nextIndex = 0

        func ordered(_ values: [String]) -> [String] {
            guard !values.isEmpty else { return [] }
            let start = nextIndex % values.count
            nextIndex = (nextIndex + 1) % values.count
            return (0..<values.count).map { values[(start + $0) % values.count] }
        }
    }

    static func fetch(track: TrackSnapshot, isrc rawIsrc: String) async throws -> FetchOutcome? {
        let isrc = TrackSnapshot.normalizeIsrc(rawIsrc)
        guard !isrc.isEmpty || track.hasUsableMetadata else { return nil }

        let decodedBases = encodedBaseURLs.compactMap(decodeTwice)
        let bases = await endpointRotation.ordered(decodedBases)
        var logs: [String] = []
        var lastError: Error?
        var notFoundCount = 0

        for (offset, base) in bases.enumerated() {
            do {
                guard var components = URLComponents(string: "\(base)/v2/lyrics/get") else {
                    throw URLError(.badURL)
                }
                if !isrc.isEmpty {
                    components.queryItems = [URLQueryItem(name: "isrc", value: isrc)]
                } else {
                    var queryItems = [
                        URLQueryItem(name: "title", value: track.title),
                        URLQueryItem(name: "artist", value: track.artist)
                    ]
                    if !track.album.isEmpty, track.album.lowercased() != "undefined" {
                        queryItems.append(URLQueryItem(name: "album", value: track.album))
                    }
                    if track.durationMs > 0 {
                        queryItems.append(
                            URLQueryItem(
                                name: "duration",
                                value: String(
                                    format: "%.3f",
                                    locale: Locale(identifier: "en_US_POSIX"),
                                    Double(track.durationMs) / 1000
                                )
                            )
                        )
                    }
                    components.queryItems = queryItems
                }
                guard let url = components.url else { throw URLError(.badURL) }
                var request = URLRequest(url: url, timeoutInterval: requestTimeout)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("ivLyrics-iOS/1.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.ivLyricsData(for: request)
                let outcome = try parse(data: data, durationMs: track.durationMs)
                logs.append("lyricsplus: mirror #\(offset + 1) selected / type=\(outcome.sourceType)")
                var result = outcome
                result.logs = logs + outcome.logs
                return result
            } catch let error as HTTPStatusError where error.statusCode == 404 {
                notFoundCount += 1
                logs.append("lyricsplus: mirror #\(offset + 1) not found")
            } catch {
                lastError = error
                logs.append("lyricsplus: mirror #\(offset + 1) failed / \(error.localizedDescription)")
            }
        }

        if notFoundCount == bases.count { return nil }
        if let lastError { throw lastError }
        return nil
    }

    private static func decodeTwice(_ value: String) -> String? {
        guard let firstData = Data(base64Encoded: value),
              let first = String(data: firstData, encoding: .utf8),
              let secondData = Data(base64Encoded: first),
              let decoded = String(data: secondData, encoding: .utf8),
              decoded.hasPrefix("https://") else {
            return nil
        }
        return decoded
    }

    static func parse(data: Data, durationMs: Int64) throws -> FetchOutcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if isTruthyJsonValue(root["error"]) {
            throw HTTPStatusError(statusCode: 404, message: "LyricsPlus lyrics not found")
        }
        let lyrics = root["lyrics"] as? [[String: Any]] ?? []
        guard !lyrics.isEmpty else {
            throw HTTPStatusError(statusCode: 404, message: "LyricsPlus response has no lyrics")
        }
        let rawSourceType = string(root["type"]).trimmed.lowercased()
        let sourceType: String
        switch rawSourceType {
        case "word": sourceType = "word"
        case "line": sourceType = "line"
        case "none", "plain", "unsynced": sourceType = "plain"
        default:
            if lyrics.contains(where: { ($0["syllabus"] as? [[String: Any]])?.isEmpty == false }) {
                sourceType = "word"
            } else if lyrics.contains(where: { optionalMilliseconds($0["time"]) != nil }) {
                sourceType = "line"
            } else {
                sourceType = "plain"
            }
        }
        let metadata = root["metadata"] as? [String: Any]
        let agents = metadata?["agents"] as? [String: Any] ?? [:]
        let agentOrder = Array(agents.keys)
        var singerOrder: [String] = []
        var rawLines: [RawLine] = []

        for (index, item) in lyrics.enumerated() {
            let element = item["element"] as? [String: Any] ?? [:]
            let singer = string(element["singer"]).trimmed
            if !singer.isEmpty, !singerOrder.contains(singer) {
                singerOrder.append(singer)
            }
            let presentation = speakerPresentation(
                singer: singer,
                singerOrder: singerOrder,
                agentOrder: agentOrder,
                agents: agents
            )
            let rawStart = optionalMilliseconds(item["time"])
            let rawDuration = positiveMilliseconds(item["duration"])
            let rawSyllables = item["syllabus"] as? [[String: Any]] ?? []
            let parsedSyllables = rawSyllables.compactMap(parseSyllable)
            let leadSyllables = parsedSyllables.filter { !$0.isBackground }.map(\.value)
            let backgroundSyllables = parsedSyllables.filter(\.isBackground).compactMap { raw -> LyricsLine.Syllable? in
                let stripped = raw.value.text.replacingOccurrences(of: "[()（）]", with: "", options: .regularExpression)
                guard !stripped.isEmpty else { return nil }
                return LyricsLine.Syllable(
                    text: stripped,
                    startTimeMs: raw.value.startTimeMs,
                    endTimeMs: raw.value.endTimeMs
                )
            }
            let leadText = leadSyllables.map(\.text).joined().trimmed
            let backgroundText = backgroundSyllables.map(\.text).joined().trimmed
            let sourceText = string(item["text"]).trimmed
            let text = backgroundSyllables.isEmpty
                ? IvLyricsUtilities.firstNonEmpty(sourceText, parsedSyllables.map(\.value.text).joined().trimmed)
                : [leadText, backgroundText].filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty else { continue }
            let allSyllables = parsedSyllables.map(\.value)
            var effectiveStart = rawStart
            var effectiveEnd = rawStart.flatMap { start in rawDuration.map { start + $0 } }
            if let syllableStart = allSyllables.map(\.startTimeMs).min() {
                effectiveStart = min(effectiveStart ?? syllableStart, syllableStart)
            }
            if let syllableEnd = allSyllables.map(\.endTimeMs).max() {
                effectiveEnd = max(effectiveEnd ?? syllableEnd, syllableEnd)
            }
            let lineKey = string(element["key"]).trimmed.isEmpty
                ? "L\(index + 1)"
                : string(element["key"]).trimmed
            var vocalParts: [LyricsLine.VocalPart] = []
            if sourceType == "word", !backgroundSyllables.isEmpty {
                let leadPart = LyricsLine.VocalPart(
                    id: "lyricsplus-\(lineKey)-lead",
                    role: "lead",
                    speaker: presentation.speaker,
                    speakerColor: presentation.color,
                    speakerFallback: presentation.fallback,
                    kind: "vocal",
                    text: leadText,
                    syllables: leadSyllables
                )
                let backgroundPart = LyricsLine.VocalPart(
                    id: "lyricsplus-\(lineKey)-background-1",
                    role: "background",
                    speaker: presentation.speaker,
                    speakerColor: presentation.color,
                    speakerFallback: presentation.fallback,
                    kind: "vocal",
                    text: backgroundText,
                    syllables: backgroundSyllables
                )
                if !leadSyllables.isEmpty { vocalParts = [leadPart, backgroundPart] }
            }
            let line = LyricsLine(
                startTimeMs: sourceType == "plain" ? 0 : (effectiveStart ?? 0),
                endTimeMs: sourceType == "plain" ? 0 : (effectiveEnd ?? effectiveStart ?? 0),
                text: text,
                syllables: sourceType == "word" && vocalParts.isEmpty
                    ? (leadSyllables.isEmpty ? backgroundSyllables : leadSyllables)
                    : [],
                speaker: presentation.speaker,
                speakerColor: presentation.color,
                speakerFallback: presentation.fallback,
                vocalParts: vocalParts
            )
            rawLines.append(
                RawLine(
                    sourceIndex: index,
                    key: lineKey,
                    singer: singer,
                    line: line,
                    hasTiming: effectiveStart != nil,
                    hasWordTiming: !allSyllables.isEmpty
                )
            )
        }

        guard !rawLines.isEmpty else {
            throw HTTPStatusError(statusCode: 404, message: "LyricsPlus response has no renderable lyrics")
        }
        let timedRaw = fillLineEndTimes(rawLines.filter(\.hasTiming), durationMs: durationMs)
        let completeTiming = timedRaw.count == rawLines.count
        let synced = completeTiming && sourceType != "plain"
            ? timedRaw.map { demoteToSynced($0.line) }
            : nil
        let plain = rawLines.sorted { $0.sourceIndex < $1.sourceIndex }.map { demoteToPlain($0.line) }
        var karaoke: [LyricsLine]? = nil
        if completeTiming,
           sourceType == "word",
           timedRaw.allSatisfy(\.hasWordTiming) {
            let grouped = groupParallelVocals(timedRaw)
            karaoke = splitLongSoloLines(grouped)
        }
        let typeLabel = sourceType == "word" ? "Word" : (sourceType == "line" ? "Line" : "Plain")
        return FetchOutcome(
            karaoke: karaoke?.isEmpty == false ? karaoke : nil,
            synced: synced?.isEmpty == false ? synced : nil,
            plain: plain.isEmpty ? nil : plain,
            sourceType: typeLabel,
            logs: [
                "lyricsplus parsed: type=\(typeLabel) / sourceLines=\(rawLines.count) / karaokeLines=\(karaoke?.count ?? 0)"
            ]
        )
    }

    private static func parseSyllable(_ object: [String: Any]) -> RawSyllable? {
        let text = string(object["text"])
        guard !text.trimmed.isEmpty,
              let start = optionalMilliseconds(object["time"]) else { return nil }
        let duration = positiveMilliseconds(object["duration"]) ?? 1
        return RawSyllable(
            value: LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: start + duration),
            isBackground: (object["isBackground"] as? Bool) == true
        )
    }

    private static func fillLineEndTimes(_ lines: [RawLine], durationMs: Int64) -> [RawLine] {
        let ordered = lines.sorted {
            $0.line.startTimeMs == $1.line.startTimeMs
                ? $0.sourceIndex < $1.sourceIndex
                : $0.line.startTimeMs < $1.line.startTimeMs
        }
        return ordered.enumerated().map { index, raw in
            var copy = raw
            if copy.line.endTimeMs <= copy.line.startTimeMs {
                let nextStart = index + 1 < ordered.count ? ordered[index + 1].line.startTimeMs : -1
                copy.line.endTimeMs = nextStart > copy.line.startTimeMs
                    ? nextStart
                    : max(
                        copy.line.startTimeMs + 1,
                        durationMs > copy.line.startTimeMs ? durationMs : copy.line.startTimeMs + 3_000
                    )
            }
            return copy
        }
    }

    private static func demoteToSynced(_ line: LyricsLine) -> LyricsLine {
        LyricsLine(
            startTimeMs: line.startTimeMs,
            endTimeMs: line.endTimeMs,
            text: line.text,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback
        )
    }

    private static func demoteToPlain(_ line: LyricsLine) -> LyricsLine {
        LyricsLine(
            startTimeMs: 0,
            endTimeMs: 0,
            text: line.text,
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback
        )
    }

    private static func groupParallelVocals(_ rawLines: [RawLine]) -> [LyricsLine] {
        guard rawLines.count > 1 else { return rawLines.map(\.line) }
        var parents = Array(rawLines.indices)
        func root(_ index: Int, parents: inout [Int]) -> Int {
            var current = index
            while parents[current] != current { current = parents[current] }
            var cursor = index
            while parents[cursor] != cursor {
                let next = parents[cursor]
                parents[cursor] = current
                cursor = next
            }
            return current
        }
        var parallelSeeds: [Int] = []
        for left in rawLines.indices {
            guard !rawLines[left].singer.isEmpty else { continue }
            for right in rawLines.indices where right > left {
                if rawLines[right].line.startTimeMs >= rawLines[left].line.endTimeMs { break }
                guard !rawLines[right].singer.isEmpty else { continue }
                let overlap = min(rawLines[left].line.endTimeMs, rawLines[right].line.endTimeMs)
                    - max(rawLines[left].line.startTimeMs, rawLines[right].line.startTimeMs)
                guard overlap > 0 else { continue }
                let leftRoot = root(left, parents: &parents)
                let rightRoot = root(right, parents: &parents)
                if leftRoot != rightRoot { parents[rightRoot] = leftRoot }
                if rawLines[left].singer != rawLines[right].singer,
                   overlap >= parallelMinimumOverlapMs {
                    parallelSeeds.append(left)
                }
            }
        }

        let parallelRoots = Set(parallelSeeds.map { root($0, parents: &parents) })
        var components: [Int: [RawLine]] = [:]
        for index in rawLines.indices {
            components[root(index, parents: &parents), default: []].append(rawLines[index])
        }
        return components
            .sorted {
                ($0.value.map(\.sourceIndex).min() ?? 0) < ($1.value.map(\.sourceIndex).min() ?? 0)
            }
            .flatMap { componentRoot, component -> [LyricsLine] in
                let ordered = component.sorted {
                    $0.line.startTimeMs == $1.line.startTimeMs
                        ? $0.sourceIndex < $1.sourceIndex
                        : $0.line.startTimeMs < $1.line.startTimeMs
                }
                guard parallelRoots.contains(componentRoot) else {
                    return ordered.map(\.line)
                }
                return createParallelVocalSegments(ordered)
            }
            .sorted { $0.startTimeMs == $1.startTimeMs ? $0.endTimeMs < $1.endTimeMs : $0.startTimeMs < $1.startTimeMs }
    }

    private static func createParallelVocalSegments(_ lines: [RawLine]) -> [LyricsLine] {
        let prepared = lines.sorted {
            $0.line.startTimeMs == $1.line.startTimeMs
                ? $0.sourceIndex < $1.sourceIndex
                : $0.line.startTimeMs < $1.line.startTimeMs
        }
        let componentLanes = buildSingerVocalLanes(prepared)
        let preferredSinger = chooseLeadLaneIndex(componentLanes).map { componentLanes[$0].singer } ?? ""
        guard countSourceLines(prepared) > parallelMaximumSourceLines else {
            return [makeParallelLine(prepared, preferredSinger: preferredSinger, idSuffix: "segment-1")]
        }

        var segments: [LyricsLine] = []
        var remaining = prepared
        var forcedStartTimeMs = prepared[0].line.startTimeMs
        var iteration = 0
        while countSourceLines(remaining) > parallelMaximumSourceLines,
              iteration < lines.count {
            iteration += 1
            guard let split = findParallelSegmentSplit(remaining, currentStartTimeMs: forcedStartTimeMs) else {
                return [makeParallelLine(prepared, preferredSinger: preferredSinger, idSuffix: "segment-1")]
            }
            var segment = makeParallelLine(
                split.left,
                preferredSinger: preferredSinger,
                idSuffix: "segment-\(segments.count + 1)"
            )
            guard !segment.vocalParts.isEmpty,
                  forcedStartTimeMs <= split.leftEndTimeMs else {
                return [makeParallelLine(prepared, preferredSinger: preferredSinger, idSuffix: "segment-1")]
            }
            segment.startTimeMs = forcedStartTimeMs
            segment.endTimeMs = split.leftEndTimeMs
            segments.append(segment)
            remaining = split.right
            forcedStartTimeMs = split.nextStartTimeMs
        }

        var finalSegment = makeParallelLine(
            remaining,
            preferredSinger: preferredSinger,
            idSuffix: "segment-\(segments.count + 1)"
        )
        guard !finalSegment.vocalParts.isEmpty else {
            return [makeParallelLine(prepared, preferredSinger: preferredSinger, idSuffix: "segment-1")]
        }
        finalSegment.startTimeMs = forcedStartTimeMs
        segments.append(finalSegment)
        return segments
    }

    private static func findParallelSegmentSplit(
        _ lines: [RawLine],
        currentStartTimeMs: Int64
    ) -> ParallelSplit? {
        let ordered = lines.sorted {
            $0.line.startTimeMs == $1.line.startTimeMs
                ? $0.sourceIndex < $1.sourceIndex
                : $0.line.startTimeMs < $1.line.startTimeMs
        }
        guard countSourceLines(ordered) > parallelMaximumSourceLines else { return nil }
        var sourceKeys: [String] = []
        var nominalBoundary: Int64?
        for raw in ordered where !sourceKeys.contains(raw.key) {
            sourceKeys.append(raw.key)
            if sourceKeys.count == parallelMaximumSourceLines + 1 {
                nominalBoundary = raw.line.startTimeMs
                break
            }
        }
        guard let nominalBoundary else { return nil }
        let firstSourceKeys = Set(sourceKeys.prefix(parallelMaximumSourceLines))
        var candidateTimes = Set<Int64>([nominalBoundary])
        for raw in ordered where firstSourceKeys.contains(raw.key) {
            for syllable in sourceSyllables(raw) {
                if syllable.startTimeMs > currentStartTimeMs,
                   syllable.startTimeMs <= nominalBoundary {
                    candidateTimes.insert(syllable.startTimeMs)
                }
                if syllable.endTimeMs > currentStartTimeMs,
                   syllable.endTimeMs <= nominalBoundary {
                    candidateTimes.insert(syllable.endTimeMs)
                }
            }
        }

        let candidates = candidateTimes.compactMap { candidateTime -> ParallelSplit? in
            let partition = partitionParallelComponent(ordered, at: candidateTime)
            let leftKeyCount = countSourceLines(partition.left)
            guard leftKeyCount >= 2,
                  leftKeyCount <= parallelMaximumSourceLines,
                  !partition.right.isEmpty,
                  Set(partition.left.map(\.singer).filter { !$0.isEmpty }).count >= 2 else {
                return nil
            }
            let leftSyllables = partition.left.flatMap(sourceSyllables)
            let rightSyllables = partition.right.flatMap(sourceSyllables)
            guard let leftEndTimeMs = leftSyllables.map(\.endTimeMs).max(),
                  let rightStartTimeMs = rightSyllables.map(\.startTimeMs).min() else {
                return nil
            }
            let nextStartTimeMs = max(leftEndTimeMs, rightStartTimeMs)
            let delayedRight = rightSyllables.filter { $0.startTimeMs < nextStartTimeMs }
            guard !delayedRight.contains(where: { $0.endTimeMs <= nextStartTimeMs }) else { return nil }
            let maximumDelayMs = delayedRight.reduce(Int64(0)) {
                max($0, nextStartTimeMs - $1.startTimeMs)
            }
            guard maximumDelayMs <= parallelMaximumSegmentDelayMs else { return nil }
            return ParallelSplit(
                left: partition.left,
                right: partition.right,
                leftEndTimeMs: leftEndTimeMs,
                nextStartTimeMs: nextStartTimeMs,
                leftKeyCount: leftKeyCount,
                maximumDelayMs: maximumDelayMs,
                distanceMs: abs(candidateTime - nominalBoundary)
            )
        }
        return candidates.sorted { left, right in
            if left.leftKeyCount != right.leftKeyCount { return left.leftKeyCount > right.leftKeyCount }
            if left.maximumDelayMs != right.maximumDelayMs { return left.maximumDelayMs < right.maximumDelayMs }
            if left.distanceMs != right.distanceMs { return left.distanceMs < right.distanceMs }
            return left.leftEndTimeMs > right.leftEndTimeMs
        }.first
    }

    private static func partitionParallelComponent(
        _ lines: [RawLine],
        at candidateTimeMs: Int64
    ) -> (left: [RawLine], right: [RawLine]) {
        var left: [RawLine] = []
        var right: [RawLine] = []
        for raw in lines {
            if let fragment = slice(raw, at: candidateTimeMs, takeLeft: true) { left.append(fragment) }
            if let fragment = slice(raw, at: candidateTimeMs, takeLeft: false) { right.append(fragment) }
        }
        return (left, right)
    }

    private static func slice(_ raw: RawLine, at boundaryMs: Int64, takeLeft: Bool) -> RawLine? {
        var leadSyllables = sliceSyllables(raw.line.syllables, at: boundaryMs, takeLeft: takeLeft)
        var vocalParts = raw.line.vocalParts.compactMap {
            sliceVocalPart($0, at: boundaryMs, takeLeft: takeLeft)
        }
        if !vocalParts.isEmpty {
            var leadIndex = vocalParts.firstIndex { $0.role == "lead" }
            if leadIndex == nil {
                vocalParts[0] = withVocalRole(vocalParts[0], role: "lead")
                leadIndex = 0
            }
            leadSyllables = vocalParts[leadIndex!].syllables
            if vocalParts.count == 1 { vocalParts.removeAll() }
        }
        guard !leadSyllables.isEmpty else { return nil }
        let allSyllables = vocalParts.isEmpty
            ? leadSyllables
            : vocalParts.flatMap(\.syllables)
        guard let startTimeMs = allSyllables.map(\.startTimeMs).min(),
              let endTimeMs = allSyllables.map(\.endTimeMs).max() else { return nil }
        var line = raw.line
        line.startTimeMs = startTimeMs
        line.endTimeMs = endTimeMs
        line.text = vocalParts.isEmpty
            ? leadSyllables.map(\.text).joined().trimmed
            : vocalParts.map(\.text).joined(separator: " ").trimmed
        line.syllables = vocalParts.isEmpty ? leadSyllables : []
        line.vocalParts = vocalParts
        guard !line.text.isEmpty else { return nil }
        return RawLine(
            sourceIndex: raw.sourceIndex,
            key: raw.key,
            singer: raw.singer,
            line: line,
            hasTiming: true,
            hasWordTiming: raw.hasWordTiming
        )
    }

    private static func sliceSyllables(
        _ syllables: [LyricsLine.Syllable],
        at boundaryMs: Int64,
        takeLeft: Bool
    ) -> [LyricsLine.Syllable] {
        syllables.filter { syllable in
            let midpoint = syllable.startTimeMs + (syllable.endTimeMs - syllable.startTimeMs) / 2
            return (midpoint <= boundaryMs) == takeLeft
        }
    }

    private static func sliceVocalPart(
        _ part: LyricsLine.VocalPart,
        at boundaryMs: Int64,
        takeLeft: Bool
    ) -> LyricsLine.VocalPart? {
        let syllables = sliceSyllables(part.syllables, at: boundaryMs, takeLeft: takeLeft)
        guard !syllables.isEmpty else { return nil }
        return LyricsLine.VocalPart(
            id: part.id,
            role: part.role,
            speaker: part.speaker,
            speakerColor: part.speakerColor,
            speakerFallback: part.speakerFallback,
            kind: part.kind,
            text: syllables.map(\.text).joined().trimmed,
            syllables: syllables,
            pronunciationText: part.pronunciationText,
            translationText: part.translationText,
            furiganaText: part.furiganaText
        )
    }

    private static func withVocalRole(
        _ part: LyricsLine.VocalPart,
        role: String,
        idSuffix: String = ""
    ) -> LyricsLine.VocalPart {
        LyricsLine.VocalPart(
            id: idSuffix.isEmpty ? part.id : "\(part.id)-\(idSuffix)",
            role: role,
            speaker: part.speaker,
            speakerColor: part.speakerColor,
            speakerFallback: part.speakerFallback,
            kind: part.kind,
            text: part.text,
            syllables: part.syllables,
            pronunciationText: part.pronunciationText,
            translationText: part.translationText,
            furiganaText: part.furiganaText
        )
    }

    private static func sourceSyllables(_ raw: RawLine) -> [LyricsLine.Syllable] {
        raw.line.vocalParts.isEmpty
            ? raw.line.syllables
            : raw.line.vocalParts.flatMap(\.syllables)
    }

    private static func countSourceLines(_ lines: [RawLine]) -> Int {
        Set(lines.map(\.key)).count
    }

    private static func buildSingerVocalLanes(_ lines: [RawLine]) -> [VocalLane] {
        var singerOrder: [String] = []
        var singerLines: [String: [RawLine]] = [:]
        for source in lines {
            guard !source.singer.isEmpty,
                  let raw = leadRawLine(source) else { continue }
            if singerLines[raw.singer] == nil { singerOrder.append(raw.singer) }
            singerLines[raw.singer, default: []].append(raw)
        }
        var result: [VocalLane] = []
        for singer in singerOrder {
            let entries = (singerLines[singer] ?? []).sorted {
                $0.line.startTimeMs == $1.line.startTimeMs
                    ? $0.sourceIndex < $1.sourceIndex
                    : $0.line.startTimeMs < $1.line.startTimeMs
            }
            var singerLanes: [VocalLane] = []
            for raw in entries {
                if let index = singerLanes.firstIndex(where: { $0.endTimeMs <= raw.line.startTimeMs }) {
                    singerLanes[index].lines.append(raw)
                    singerLanes[index].endTimeMs = max(singerLanes[index].endTimeMs, raw.line.endTimeMs)
                } else {
                    singerLanes.append(VocalLane(singer: singer, lines: [raw], endTimeMs: raw.line.endTimeMs))
                }
            }
            result.append(contentsOf: singerLanes)
        }
        return result
    }

    private static func leadRawLine(_ raw: RawLine) -> RawLine? {
        guard !raw.line.vocalParts.isEmpty else {
            return raw.line.syllables.isEmpty ? nil : raw
        }
        guard let part = raw.line.vocalParts.first(where: { $0.role == "lead" })
            ?? raw.line.vocalParts.first,
              !part.syllables.isEmpty else { return nil }
        var line = raw.line
        line.startTimeMs = part.startTimeMs
        line.endTimeMs = part.endTimeMs
        line.text = part.text
        line.syllables = part.syllables
        line.speaker = part.speaker
        line.speakerColor = part.speakerColor
        line.speakerFallback = part.speakerFallback
        line.kind = part.kind
        line.vocalParts = []
        return RawLine(
            sourceIndex: raw.sourceIndex,
            key: raw.key,
            singer: raw.singer,
            line: line,
            hasTiming: raw.hasTiming,
            hasWordTiming: raw.hasWordTiming
        )
    }

    private static func chooseLeadLaneIndex(
        _ lanes: [VocalLane],
        preferredSinger: String = ""
    ) -> Int? {
        guard !lanes.isEmpty else { return nil }
        func ranked(_ indexes: [Int]) -> [Int] {
            indexes.sorted { leftIndex, rightIndex in
                let left = lanes[leftIndex]
                let right = lanes[rightIndex]
                if left.durationMs != right.durationMs { return left.durationMs > right.durationMs }
                if left.lines.count != right.lines.count { return left.lines.count > right.lines.count }
                if left.startTimeMs != right.startTimeMs { return left.startTimeMs < right.startTimeMs }
                return left.minimumSourceIndex < right.minimumSourceIndex
            }
        }
        guard let strongest = ranked(Array(lanes.indices)).first else { return nil }
        guard !preferredSinger.isEmpty,
              let preferred = ranked(lanes.indices.filter { lanes[$0].singer == preferredSinger }).first,
              Double(lanes[preferred].durationMs) >= Double(lanes[strongest].durationMs) * 0.5 else {
            return strongest
        }
        return preferred
    }

    private static func makeParallelLine(
        _ lines: [RawLine],
        preferredSinger: String,
        idSuffix: String
    ) -> LyricsLine {
        let ordered = lines.sorted {
            $0.line.startTimeMs == $1.line.startTimeMs
                ? $0.sourceIndex < $1.sourceIndex
                : $0.line.startTimeMs < $1.line.startTimeMs
        }
        guard ordered.count > 1 else {
            return ordered.first?.line ?? LyricsLine(startTimeMs: 0, endTimeMs: 0, text: "")
        }
        let lanes = buildSingerVocalLanes(ordered)
        guard lanes.count > 1,
              let leadLaneIndex = chooseLeadLaneIndex(lanes, preferredSinger: preferredSinger) else {
            return ordered[0].line
        }
        let laneOrder = [leadLaneIndex] + lanes.indices
            .filter { $0 != leadLaneIndex }
            .sorted {
                let left = lanes[$0]
                let right = lanes[$1]
                if left.startTimeMs != right.startTimeMs { return left.startTimeMs < right.startTimeMs }
                return left.minimumSourceIndex < right.minimumSourceIndex
            }
        var parts = laneOrder.compactMap { index -> LyricsLine.VocalPart? in
            mergedVocalPart(
                lanes[index],
                role: index == leadLaneIndex ? "lead" : "background",
                idSuffix: idSuffix
            )
        }
        let explicitBackgroundParts = ordered
            .flatMap(\.line.vocalParts)
            .filter { $0.role != "lead" }
            .sorted { $0.startTimeMs < $1.startTimeMs }
            .map { withVocalRole($0, role: "background", idSuffix: idSuffix) }
        parts.append(contentsOf: explicitBackgroundParts)
        guard parts.count > 1 else { return ordered[0].line }
        let lead = lanes[leadLaneIndex].lines[0]
        return LyricsLine(
            startTimeMs: parts.map(\.startTimeMs).min() ?? lead.line.startTimeMs,
            endTimeMs: parts.map(\.endTimeMs).max() ?? lead.line.endTimeMs,
            text: parts.map(\.text).joined(separator: " / "),
            speaker: lead.line.speaker,
            speakerColor: lead.line.speakerColor,
            speakerFallback: lead.line.speakerFallback,
            vocalParts: parts
        )
    }

    private static func mergedVocalPart(
        _ lane: VocalLane,
        role: String,
        idSuffix: String
    ) -> LyricsLine.VocalPart? {
        let lines = lane.lines.sorted {
            $0.line.startTimeMs == $1.line.startTimeMs
                ? $0.sourceIndex < $1.sourceIndex
                : $0.line.startTimeMs < $1.line.startTimeMs
        }
        guard let first = lines.first else { return nil }
        var syllables: [LyricsLine.Syllable] = []
        for raw in lines {
            if let previous = syllables.last,
               let next = raw.line.syllables.first,
               previous.text.last?.isWhitespace != true,
               next.text.first?.isWhitespace != true {
                syllables.append(
                    LyricsLine.Syllable(
                        text: " ",
                        startTimeMs: next.startTimeMs,
                        endTimeMs: next.startTimeMs
                    )
                )
            }
            syllables.append(contentsOf: raw.line.syllables)
        }
        guard !syllables.isEmpty else { return nil }
        let keys = lines.map(\.key).joined(separator: "+")
        return LyricsLine.VocalPart(
            id: "lyricsplus-\(keys)-\(idSuffix)-\(role)",
            role: role,
            speaker: first.line.speaker,
            speakerColor: first.line.speakerColor,
            speakerFallback: first.line.speakerFallback,
            kind: "vocal",
            text: lines.map(\.line.text).joined(separator: " / "),
            syllables: syllables
        )
    }

    private static func splitLongSoloLines(_ lines: [LyricsLine]) -> [LyricsLine] {
        lines.enumerated().flatMap { index, line in
            let previous = index > 0 ? lines[index - 1] : nil
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            return splitLongSoloLine(line, previous: previous, next: next)
        }
    }

    private static func splitLongSoloLine(_ line: LyricsLine, previous: LyricsLine?, next: LyricsLine?) -> [LyricsLine] {
        let syllables = line.syllables
        guard line.vocalParts.isEmpty,
              syllables.count >= 2,
              measureWidth(line.text) > splitTriggerWidth,
              (previous == nil || previous!.endTimeMs <= line.startTimeMs),
              (next == nil || next!.startTimeMs >= line.endTimeMs),
              syllables.map(\.text).joined().trimmed == line.text.trimmed else {
            return [line]
        }
        for index in syllables.indices {
            let item = syllables[index]
            guard item.endTimeMs >= item.startTimeMs else { return [line] }
            if index > 0 {
                let prior = syllables[index - 1]
                guard item.startTimeMs >= prior.endTimeMs else { return [line] }
            }
        }
        let candidates = (1..<syllables.count).filter { safeBoundary(syllables[$0 - 1], syllables[$0]) != nil }
        guard !candidates.isEmpty else { return [line] }
        let minimumCount = max(2, Int(ceil(measureWidth(line.text) / splitHardWidth)))
        let maximumCount = min(splitMaximumSegments, candidates.count + 1)
        guard minimumCount <= maximumCount else { return [line] }

        var bestBoundaries: [Int]?
        var bestScore = Double.greatestFiniteMagnitude
        for segmentCount in minimumCount...maximumCount {
            var chosen: [Int] = []
            chooseBoundaries(
                candidates: candidates,
                needed: segmentCount - 1,
                cursor: 0,
                chosen: &chosen
            ) { boundaries in
                let points = [0] + boundaries + [syllables.count]
                let target = measureWidth(line.text) / Double(segmentCount)
                var score = 0.0
                for segment in 0..<segmentCount {
                    let slice = Array(syllables[points[segment]..<points[segment + 1]])
                    let width = measureWidth(slice.map(\.text).joined())
                    let duration = (slice.last?.endTimeMs ?? 0) - (slice.first?.startTimeMs ?? 0)
                    guard width >= splitMinimumWidth,
                          width <= splitHardWidth,
                          duration >= splitMinimumDurationMs else { return }
                    score += pow(width - target, 2)
                    if segment < segmentCount - 1,
                       let boundary = safeBoundary(syllables[points[segment + 1] - 1], syllables[points[segment + 1]]) {
                        score += boundary
                    }
                }
                if score < bestScore {
                    bestScore = score
                    bestBoundaries = boundaries
                }
            }
            if bestBoundaries != nil { break }
        }
        guard let boundaries = bestBoundaries else { return [line] }
        let points = [0] + boundaries + [syllables.count]
        return (0..<(points.count - 1)).map { index in
            let slice = Array(syllables[points[index]..<points[index + 1]])
            return LyricsLine(
                startTimeMs: index == 0 ? min(line.startTimeMs, slice[0].startTimeMs) : slice[0].startTimeMs,
                endTimeMs: index == points.count - 2 ? max(line.endTimeMs, slice.last!.endTimeMs) : slice.last!.endTimeMs,
                text: slice.map(\.text).joined().trimmed,
                syllables: slice,
                speaker: line.speaker,
                speakerColor: line.speakerColor,
                speakerFallback: line.speakerFallback
            )
        }
    }

    private static func chooseBoundaries(
        candidates: [Int],
        needed: Int,
        cursor: Int,
        chosen: inout [Int],
        visit: ([Int]) -> Void
    ) {
        if chosen.count == needed {
            visit(chosen)
            return
        }
        guard cursor < candidates.count,
              candidates.count - cursor >= needed - chosen.count else { return }
        for index in cursor..<candidates.count {
            chosen.append(candidates[index])
            chooseBoundaries(candidates: candidates, needed: needed, cursor: index + 1, chosen: &chosen, visit: visit)
            chosen.removeLast()
        }
    }

    private static func safeBoundary(_ left: LyricsLine.Syllable, _ right: LyricsLine.Syllable) -> Double? {
        guard left.endTimeMs <= right.startTimeMs,
              let leftCharacter = boundaryCharacter(left.text, fromEnd: true),
              let rightCharacter = boundaryCharacter(right.text, fromEnd: false),
              !"([{（「『【〈《".contains(leftCharacter),
              !")]})）」』】〉》、。，．！？?!".contains(rightCharacter),
              !"ゃゅょっぁぃぅぇぉゎャュョッァィゥェォヮー々".contains(rightCharacter) else {
            return nil
        }
        let hasWhitespace = left.text.last?.isWhitespace == true || right.text.first?.isWhitespace == true
        let punctuation = "。！？?!…；;：:、，,.".contains(leftCharacter)
        let scriptChange = (isCjk(leftCharacter) && isLatinOrNumber(rightCharacter))
            || (isLatinOrNumber(leftCharacter) && isCjk(rightCharacter))
        if isLatinOrNumber(leftCharacter), isLatinOrNumber(rightCharacter), !hasWhitespace, !punctuation {
            return nil
        }
        guard hasWhitespace || punctuation || scriptChange else { return nil }
        return hasWhitespace ? 0 : (punctuation ? 1 : 10)
    }

    private static func boundaryCharacter(_ text: String, fromEnd: Bool) -> Character? {
        let values = text.filter { !$0.isWhitespace }
        return fromEnd ? values.last : values.first
    }

    private static func measureWidth(_ text: String) -> Double {
        text.reduce(0) { total, character in
            if character.isWhitespace { return total + 0.33 }
            if isCjk(character) { return total + 1.0 }
            if character.isASCIIUppercase { return total + 0.72 }
            if character.isASCIILowercase { return total + 0.58 }
            if character.isNumber { return total + 0.62 }
            if ".,'’!?;:()-".contains(character) { return total + 0.38 }
            return total + 0.8
        }
    }

    private static func isLatinOrNumber(_ character: Character) -> Bool {
        character.isASCIIUppercase || character.isASCIILowercase || character.isNumber
    }

    private static func isCjk(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3040...0x30ff).contains(value)
                || (0x3400...0x9fff).contains(value)
                || (0xac00...0xd7af).contains(value)
                || (0xf900...0xfaff).contains(value)
        }
    }

    private static func speakerPresentation(
        singer: String,
        singerOrder: [String],
        agentOrder: [String],
        agents: [String: Any]
    ) -> SpeakerPresentation {
        guard !singer.isEmpty else { return SpeakerPresentation(speaker: "NORMAL", color: "", fallback: "") }
        let index = singerOrder.firstIndex(of: singer) ?? agentOrder.firstIndex(of: singer) ?? 0
        if index == 0 { return SpeakerPresentation(speaker: "NORMAL", color: "", fallback: "") }
        let agent = agents[singer] as? [String: Any]
        let palette: (String, String)
        if string(agent?["type"]).lowercased() == "group" {
            let groupPalette = speakerPalette.filter { $0.1.hasPrefix("DUET") }
            let priorGroupCount = singerOrder.prefix(index).filter { candidate in
                let metadata = agents[candidate] as? [String: Any]
                return string(metadata?["type"]).lowercased() == "group"
            }.count
            palette = groupPalette[priorGroupCount % groupPalette.count]
        } else {
            palette = speakerPalette[(index - 1) % speakerPalette.count]
        }
        return SpeakerPresentation(speaker: "CUSTOM", color: palette.0, fallback: palette.1)
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func isTruthyJsonValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let string = value as? String { return !string.trimmed.isEmpty }
        return true
    }

    private static func optionalMilliseconds(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        let number: Double?
        if let raw = value as? NSNumber {
            number = raw.doubleValue
        } else if let raw = value as? String, !raw.trimmed.isEmpty {
            number = Double(raw)
        } else {
            number = nil
        }
        guard let number,
              number.isFinite,
              number >= 0,
              number <= Double(Int64.max) else { return nil }
        return Int64(number.rounded())
    }

    private static func positiveMilliseconds(_ value: Any?) -> Int64? {
        guard let value = optionalMilliseconds(value), value > 0 else { return nil }
        return value
    }
}

private extension Character {
    var isASCIIUppercase: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { (65...90).contains($0.value) } == true
    }

    var isASCIILowercase: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first.map { (97...122).contains($0.value) } == true
    }
}
