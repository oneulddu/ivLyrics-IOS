import Foundation

enum CrossLineVocalNormalizer {
    static let minimumOverlapMs: Int64 = 30

    private struct Stream {
        var sourceLineIndex: Int
        var sourcePartIndex: Int
        var part: LyricsLine.VocalPart
        var startTimeMs: Int64
        var endTimeMs: Int64

        var stableKey: String {
            "line-\(sourceLineIndex)-part-\(sourcePartIndex)"
        }
    }

    private struct LaneKey: Equatable {
        var role: String
        var speaker: String
        var speakerColor: String
        var speakerFallback: String
        var kind: String
    }

    private struct Lane {
        var key: LaneKey
        var streams: [Stream]
        var endTimeMs: Int64
        var creationIndex: Int
    }

#if DEBUG
    private static let regressionChecks: Void = {
        func syllable(_ text: String, _ start: Int64, _ end: Int64) -> LyricsLine.Syllable {
            LyricsLine.Syllable(text: text, startTimeMs: start, endTimeMs: end)
        }

        func part(
            _ id: String,
            role: String,
            text: String,
            start: Int64,
            end: Int64
        ) -> LyricsLine.VocalPart {
            LyricsLine.VocalPart(
                id: id,
                role: role,
                speaker: "v2",
                kind: "vocal",
                text: text,
                syllables: [syllable(text, start, end)]
            )
        }

        let source = [
            LyricsLine(
                startTimeMs: 14_005,
                endTimeMs: 17_458,
                text: "And turn me up when you feel low (Turn it up a little bit)",
                vocalParts: [
                    part("line-5-lead", role: "lead", text: "And turn me up when you feel low", start: 14_005, end: 16_472),
                    part("line-5-background", role: "background", text: "Turn it up a little bit", start: 16_412, end: 17_458)
                ]
            ),
            LyricsLine(
                startTimeMs: 16_597,
                endTimeMs: 19_098,
                text: "This melody was meant for you",
                syllables: [syllable("This melody was meant for you", 16_597, 19_098)],
                speaker: "v2"
            )
        ]
        let sourceSnapshot = source
        let normalizedSource = normalized(source, minimumOverlapMs: minimumOverlapMs)
        assert(source == sourceSnapshot)
        assert(normalizedSource.count == 1)
        assert(normalizedSource[0].vocalParts.count == 2)
        let preservedText = normalizedSource[0].vocalParts.map(\.text).joined(separator: " / ")
        assert(preservedText.contains("And turn me up when you feel low"))
        assert(preservedText.contains("Turn it up a little bit"))
        assert(preservedText.contains("This melody was meant for you"))
        assert(normalizedSource[0].vocalParts.filter { 16_600 >= $0.startTimeMs && 16_600 < $0.endTimeMs }.count == 2)

        let triple = (0..<3).map { index in
            let startTimeMs = Int64(1_000 + index * 100)
            let endTimeMs = Int64(2_000 + index * 100)
            return LyricsLine(
                startTimeMs: startTimeMs,
                endTimeMs: endTimeMs,
                text: "voice \(index)",
                syllables: [syllable("voice \(index)", startTimeMs, endTimeMs)],
                speaker: "same"
            )
        }
        let normalizedTriple = normalized(triple, minimumOverlapMs: minimumOverlapMs)
        assert(normalizedTriple.count == 1)
        assert(normalizedTriple[0].vocalParts.count == 3)
        assert(normalizedTriple[0].vocalParts.filter { $0.role == "lead" }.count == 1)

        let separate = [
            LyricsLine(startTimeMs: 1_000, endTimeMs: 2_000, text: "first", syllables: [syllable("first", 1_000, 2_000)]),
            LyricsLine(startTimeMs: 2_000, endTimeMs: 3_000, text: "second", syllables: [syllable("second", 2_000, 3_000)])
        ]
        assert(normalized(separate, minimumOverlapMs: minimumOverlapMs) == separate)

        let incidentalOverlap = [
            LyricsLine(startTimeMs: 1_000, endTimeMs: 2_000, text: "first", syllables: [syllable("first", 1_000, 2_000)]),
            LyricsLine(startTimeMs: 1_971, endTimeMs: 2_500, text: "second", syllables: [syllable("second", 1_971, 2_500)])
        ]
        assert(normalized(incidentalOverlap, minimumOverlapMs: minimumOverlapMs) == incidentalOverlap)
    }()
#endif

    static func normalize(
        _ lines: [LyricsLine],
        minimumOverlapMs: Int64 = CrossLineVocalNormalizer.minimumOverlapMs
    ) -> [LyricsLine] {
#if DEBUG
        _ = regressionChecks
#endif
        return normalized(lines, minimumOverlapMs: max(1, minimumOverlapMs))
    }

    private static func normalized(
        _ lines: [LyricsLine],
        minimumOverlapMs: Int64
    ) -> [LyricsLine] {
        guard lines.count > 1 else { return lines }
        let streamsByLine = lines.indices.map { streams(for: lines[$0], lineIndex: $0) }
        var parents = Array(lines.indices)

        for leftIndex in lines.indices {
            guard !streamsByLine[leftIndex].isEmpty else { continue }
            for rightIndex in lines.indices where rightIndex > leftIndex {
                guard !streamsByLine[rightIndex].isEmpty,
                      hasOverlap(
                        streamsByLine[leftIndex],
                        streamsByLine[rightIndex],
                        minimumOverlapMs: minimumOverlapMs
                      ) else {
                    continue
                }
                union(leftIndex, rightIndex, parents: &parents)
            }
        }

        var components: [Int: [Int]] = [:]
        for index in lines.indices {
            components[find(index, parents: &parents), default: []].append(index)
        }

        var mergedAtIndex: [Int: LyricsLine] = [:]
        var consumedIndices = Set<Int>()
        for component in components.values where component.count > 1 {
            let orderedIndices = component.sorted()
            let componentStreams = orderedIndices
                .flatMap { streamsByLine[$0] }
                .sorted(by: streamOrder)
            guard let merged = merge(
                componentStreams,
                sourceLines: orderedIndices.map { lines[$0] }
            ) else {
                continue
            }
            let insertionIndex = orderedIndices[0]
            mergedAtIndex[insertionIndex] = merged
            consumedIndices.formUnion(orderedIndices.dropFirst())
        }

        guard !mergedAtIndex.isEmpty else { return lines }
        var result: [LyricsLine] = []
        result.reserveCapacity(lines.count - consumedIndices.count)
        for index in lines.indices {
            if let merged = mergedAtIndex[index] {
                result.append(merged)
            } else if !consumedIndices.contains(index) {
                result.append(lines[index])
            }
        }
        return result
    }

    private static func streams(for line: LyricsLine, lineIndex: Int) -> [Stream] {
        var result: [Stream] = []
        result.reserveCapacity(max(1, line.vocalParts.count))

        for (partIndex, part) in line.vocalParts.enumerated() {
            if let stream = stream(
                part: part,
                sourceLineIndex: lineIndex,
                sourcePartIndex: partIndex
            ) {
                result.append(stream)
            }
        }

        let hasLead = result.contains { normalizedRole($0.part.role) == "lead" }
        if !hasLead,
           let lead = topLevelLeadStream(line: line, lineIndex: lineIndex) {
            result.insert(lead, at: 0)
        }
        return result
    }

    private static func topLevelLeadStream(line: LyricsLine, lineIndex: Int) -> Stream? {
        guard !line.syllables.isEmpty else { return nil }
        let part = LyricsLine.VocalPart(
            id: "cross-line-\(lineIndex)-lead",
            role: "lead",
            speaker: line.speaker,
            speakerColor: line.speakerColor,
            speakerFallback: line.speakerFallback,
            kind: line.kind,
            text: displayText(line.text, syllables: line.syllables),
            syllables: line.syllables,
            pronunciationText: line.pronunciationText,
            translationText: line.translationText,
            furiganaText: line.furiganaText
        )
        return stream(part: part, sourceLineIndex: lineIndex, sourcePartIndex: -1)
    }

    private static func stream(
        part: LyricsLine.VocalPart,
        sourceLineIndex: Int,
        sourcePartIndex: Int
    ) -> Stream? {
        guard let startTimeMs = part.syllables.map(\.startTimeMs).min(),
              let endTimeMs = part.syllables.map(\.endTimeMs).max(),
              endTimeMs > startTimeMs else {
            return nil
        }
        return Stream(
            sourceLineIndex: sourceLineIndex,
            sourcePartIndex: sourcePartIndex,
            part: part,
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs
        )
    }

    private static func hasOverlap(
        _ left: [Stream],
        _ right: [Stream],
        minimumOverlapMs: Int64
    ) -> Bool {
        for leftStream in left {
            for rightStream in right {
                let overlapMs = min(leftStream.endTimeMs, rightStream.endTimeMs)
                    - max(leftStream.startTimeMs, rightStream.startTimeMs)
                if overlapMs >= minimumOverlapMs {
                    return true
                }
            }
        }
        return false
    }

    private static func merge(
        _ streams: [Stream],
        sourceLines: [LyricsLine]
    ) -> LyricsLine? {
        guard streams.count > 1 else { return nil }
        var lanes: [Lane] = []
        for stream in streams {
            let key = laneKey(for: stream.part)
            var bestLaneIndex: Int?
            for laneIndex in lanes.indices where lanes[laneIndex].key == key
                && lanes[laneIndex].endTimeMs <= stream.startTimeMs {
                if bestLaneIndex == nil
                    || lanes[laneIndex].endTimeMs > lanes[bestLaneIndex!].endTimeMs {
                    bestLaneIndex = laneIndex
                }
            }

            if let bestLaneIndex {
                lanes[bestLaneIndex].streams.append(stream)
                lanes[bestLaneIndex].endTimeMs = max(lanes[bestLaneIndex].endTimeMs, stream.endTimeMs)
            } else {
                lanes.append(
                    Lane(
                        key: key,
                        streams: [stream],
                        endTimeMs: stream.endTimeMs,
                        creationIndex: lanes.count
                    )
                )
            }
        }

        keepStrongestLeadLane(&lanes)

        lanes.sort { left, right in
            let leftRoleRank = left.key.role == "lead" ? 0 : 1
            let rightRoleRank = right.key.role == "lead" ? 0 : 1
            if leftRoleRank != rightRoleRank { return leftRoleRank < rightRoleRank }
            let leftStart = left.streams.map(\.startTimeMs).min() ?? 0
            let rightStart = right.streams.map(\.startTimeMs).min() ?? 0
            if leftStart != rightStart { return leftStart < rightStart }
            return left.creationIndex < right.creationIndex
        }

        let vocalParts = lanes.enumerated().map { laneIndex, lane in
            mergedPart(lane, laneIndex: laneIndex)
        }
        guard vocalParts.count > 1,
              let startTimeMs = streams.map(\.startTimeMs).min(),
              let endTimeMs = streams.map(\.endTimeMs).max() else {
            return nil
        }

        let primaryPart = vocalParts.first(where: { normalizedRole($0.role) == "lead" })
            ?? vocalParts[0]
        return LyricsLine(
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            text: joinedText(vocalParts.map(\.text)),
            speaker: primaryPart.speaker,
            speakerColor: primaryPart.speakerColor,
            speakerFallback: primaryPart.speakerFallback,
            kind: primaryPart.kind,
            vocalParts: vocalParts,
            pronunciationText: joined(sourceLines.map(\.pronunciationText)),
            translationText: joined(sourceLines.map(\.translationText)),
            furiganaText: joined(sourceLines.map(\.furiganaText))
        )
    }

    private static func mergedPart(_ lane: Lane, laneIndex: Int) -> LyricsLine.VocalPart {
        let streams = lane.streams.sorted(by: streamOrder)
        var syllables: [LyricsLine.Syllable] = []
        var text = ""
        for stream in streams {
            let streamText = displayText(stream.part.text, syllables: stream.part.syllables)
            let textNeedsSpace = !text.isEmpty
                && text.last?.isWhitespace != true
                && streamText.first?.isWhitespace != true
            let syllablesNeedSpace = !syllables.isEmpty
                && syllables.last?.text.last?.isWhitespace != true
                && stream.part.syllables.first?.text.first?.isWhitespace != true
            if syllablesNeedSpace {
                syllables.append(
                    LyricsLine.Syllable(
                        text: " ",
                        startTimeMs: stream.startTimeMs,
                        endTimeMs: stream.startTimeMs
                    )
                )
            }
            if textNeedsSpace {
                text.append(" ")
            }
            text.append(streamText)
            syllables.append(contentsOf: stream.part.syllables)
        }
        let first = streams[0].part
        return LyricsLine.VocalPart(
            id: "cross-line-lane-\(laneIndex)-\(streams.map(\.stableKey).joined(separator: "-"))",
            role: lane.key.role,
            speaker: first.speaker,
            speakerColor: first.speakerColor,
            speakerFallback: first.speakerFallback,
            kind: first.kind,
            text: text,
            syllables: syllables,
            pronunciationText: joined(streams.map(\.part.pronunciationText)),
            translationText: joined(streams.map(\.part.translationText)),
            furiganaText: joined(streams.map(\.part.furiganaText))
        )
    }

    private static func keepStrongestLeadLane(_ lanes: inout [Lane]) {
        let leadIndices = lanes.indices.filter { lanes[$0].key.role == "lead" }
        guard leadIndices.count > 1 else { return }
        let strongest = leadIndices.sorted { leftIndex, rightIndex in
            let left = lanes[leftIndex]
            let right = lanes[rightIndex]
            let leftDuration = left.streams.reduce(Int64(0)) {
                $0 + max(0, $1.endTimeMs - $1.startTimeMs)
            }
            let rightDuration = right.streams.reduce(Int64(0)) {
                $0 + max(0, $1.endTimeMs - $1.startTimeMs)
            }
            if leftDuration != rightDuration { return leftDuration > rightDuration }
            if left.streams.count != right.streams.count { return left.streams.count > right.streams.count }
            let leftStart = left.streams.map(\.startTimeMs).min() ?? 0
            let rightStart = right.streams.map(\.startTimeMs).min() ?? 0
            if leftStart != rightStart { return leftStart < rightStart }
            return left.creationIndex < right.creationIndex
        }[0]
        for laneIndex in leadIndices where laneIndex != strongest {
            lanes[laneIndex].key.role = "background"
        }
    }

    private static func laneKey(for part: LyricsLine.VocalPart) -> LaneKey {
        LaneKey(
            role: normalizedRole(part.role),
            speaker: part.speaker,
            speakerColor: part.speakerColor,
            speakerFallback: part.speakerFallback,
            kind: part.kind
        )
    }

    private static func normalizedRole(_ role: String) -> String {
        role.trimmed.lowercased() == "background" ? "background" : "lead"
    }

    private static func displayText(
        _ text: String,
        syllables: [LyricsLine.Syllable]
    ) -> String {
        let normalized = text.trimmed
        return normalized.isEmpty ? syllables.map(\.text).joined().trimmed : normalized
    }

    private static func joined(_ values: [String]) -> String {
        values.map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private static func joinedText(_ values: [String]) -> String {
        values.map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func streamOrder(_ left: Stream, _ right: Stream) -> Bool {
        if left.startTimeMs != right.startTimeMs { return left.startTimeMs < right.startTimeMs }
        if left.endTimeMs != right.endTimeMs { return left.endTimeMs < right.endTimeMs }
        if left.sourceLineIndex != right.sourceLineIndex { return left.sourceLineIndex < right.sourceLineIndex }
        return left.sourcePartIndex < right.sourcePartIndex
    }

    private static func find(_ index: Int, parents: inout [Int]) -> Int {
        var root = index
        while parents[root] != root {
            root = parents[root]
        }
        var cursor = index
        while parents[cursor] != cursor {
            let next = parents[cursor]
            parents[cursor] = root
            cursor = next
        }
        return root
    }

    private static func union(_ left: Int, _ right: Int, parents: inout [Int]) {
        let leftRoot = find(left, parents: &parents)
        let rightRoot = find(right, parents: &parents)
        if leftRoot != rightRoot {
            parents[rightRoot] = leftRoot
        }
    }
}
