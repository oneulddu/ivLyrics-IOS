import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum UnisonParser {
    private static let maxLines = 10_000
    private static let maxSyllables = 50_000
    private static let maxXMLDepth = 128
    private static let maxXMLNodes = 50_000
    private static let maxXMLTextCharacters = 500_000
    private static let maxTimeMs = UnisonLyricsData.maximumDurationMs
    private static let palette = [
        ProviderSpeakerPresentation(speaker: "CUSTOM", color: "#a8ccff", fallback: "MALE 1"),
        ProviderSpeakerPresentation(speaker: "CUSTOM", color: "#ffb8c7", fallback: "FEMALE 1"),
        ProviderSpeakerPresentation(speaker: "CUSTOM", color: "#e4d8ff", fallback: "DUET 1"),
        ProviderSpeakerPresentation(speaker: "CUSTOM", color: "#9ae8d4", fallback: "MALE 2"),
        ProviderSpeakerPresentation(speaker: "CUSTOM", color: "#ffd6b3", fallback: "FEMALE 2")
    ]

    static func parse(_ data: UnisonLyricsData, durationMs: Int64?,
                      xmlEventObserver: (() -> Void)? = nil) throws -> UnisonParsedLyrics {
        try checkCancellation()
        switch data.format.lowercased() {
        case "ttml": return try parseTTML(data.lyrics, xmlEventObserver: xmlEventObserver)
        case "lrc": return try parseLRC(data.lyrics, durationMs: durationMs)
        case "plain":
            let source = stripBOM(data.lyrics)
            try validateLineCount(source)
            let lines = ProviderLRC.splitPlainText(source)
            guard lines.count <= maxLines else { throw LyricsProviderError.providerFormat }
            guard !lines.isEmpty else { throw LyricsProviderError.miss }
            return UnisonParsedLyrics(lines: lines, timing: .plain)
        default: throw LyricsProviderError.providerFormat
        }
    }

    private static func parseLRC(_ source: String, durationMs: Int64?) throws -> UnisonParsedLyrics {
        let timestampPattern = #"\[(\d+):(\d+)(?:[.:](\d+))?\]"#
        guard let timestampRegex = try? NSRegularExpression(pattern: timestampPattern) else {
            throw LyricsProviderError.providerFormat
        }
        var offset: Int64 = 0
        var pairs: [(Int64, String)] = []
        let source = stripBOM(source)
        try validateLineCount(source)
        for rawLine in source.components(separatedBy: .newlines) {
            try checkCancellation()
            if let values = rawLine.firstMatch(#"^\[offset:([^]]+)\]"#) {
                guard let value = Int64(values[1]), absSafely(value) <= maxTimeMs else {
                    throw LyricsProviderError.providerFormat
                }
                offset = value
                continue
            }
            if rawLine.range(of: #"^\[(ar|al|ti|by|re|ve|length):"#,
                             options: [.regularExpression, .caseInsensitive]) != nil { continue }
            let nsRange = NSRange(rawLine.startIndex..., in: rawLine)
            let matches = timestampRegex.matches(in: rawLine, range: nsRange)
            guard !matches.isEmpty else { continue }
            let text = timestampRegex.stringByReplacingMatches(in: rawLine, range: nsRange, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let source = rawLine as NSString
            for match in matches {
                guard pairs.count < maxLines,
                      let minutes = Int64(source.substring(with: match.range(at: 1))),
                      let seconds = Int64(source.substring(with: match.range(at: 2))),
                      seconds < 60 else { throw LyricsProviderError.providerFormat }
                let fraction = match.range(at: 3).location == NSNotFound ? "" : source.substring(with: match.range(at: 3))
                guard fraction.count <= 3,
                      let fractionValue = fraction.isEmpty ? 0 : Int64(fraction) else {
                    throw LyricsProviderError.providerFormat
                }
                let fractionMs = fraction.isEmpty ? 0
                    : (fraction.count == 1 ? fractionValue * 100
                       : (fraction.count == 2 ? fractionValue * 10 : fractionValue))
                guard let minuteMs = multiplied(minutes, by: 60_000),
                      let secondMs = multiplied(seconds, by: 1_000),
                      let base = added(minuteMs, secondMs),
                      let withFraction = added(base, fractionMs),
                      let adjusted = added(withFraction, offset),
                      adjusted <= maxTimeMs else { throw LyricsProviderError.providerFormat }
                pairs.append((max(0, adjusted), text))
            }
        }
        if pairs.isEmpty {
            let plain = ProviderLRC.splitPlainText(stripBOM(source)).filter {
                $0.text.range(of: #"^\[[^]]+:"#, options: .regularExpression) == nil
            }
            guard plain.count <= maxLines else { throw LyricsProviderError.providerFormat }
            guard !plain.isEmpty else { throw LyricsProviderError.miss }
            return UnisonParsedLyrics(lines: plain, timing: .plain)
        }
        let lines = try ProviderLRC.buildLines(from: pairs, durationMs: durationMs,
                                               severeRegressionMs: 86_400_000, minimumValidRatio: 0)
        return UnisonParsedLyrics(lines: lines, timing: .lineSynced)
    }

    private static func parseTTML(_ source: String, xmlEventObserver: (() -> Void)?) throws -> UnisonParsedLyrics {
        guard let xmlData = declareMissingNamespaces(source).data(using: .utf8) else {
            throw LyricsProviderError.providerFormat
        }
        let builder = XMLTreeBuilder(maxDepth: maxXMLDepth, maxNodes: maxXMLNodes,
                                     maxTextCharacters: maxXMLTextCharacters,
                                     eventObserver: xmlEventObserver)
        let parser = XMLParser(data: xmlData)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if builder.wasCancelled { throw CancellationError() }
        guard parsed, builder.failure == nil else { throw LyricsProviderError.providerFormat }

        var agentOrder: [String: Int] = [:]
        for agent in elements(named: "agent", roots: builder.roots) {
            let id = attribute(agent, "id")
            if !id.isEmpty, agentOrder[id] == nil { agentOrder[id] = agentOrder.count }
        }
        let paragraphs = elements(named: "p", roots: builder.roots)
        guard paragraphs.count <= maxLines else { throw LyricsProviderError.providerFormat }
        var lines: [ProviderLyricLine] = []
        var syllableCount = 0
        for (index, paragraph) in paragraphs.enumerated() {
            try checkCancellation()
            let start = try optionalTime(attribute(paragraph, "begin")) ?? 0
            guard start < maxTimeMs else { throw LyricsProviderError.providerFormat }
            let explicitEnd = try optionalTime(attribute(paragraph, "end"))
            let duration = try optionalTime(attribute(paragraph, "dur"))
            let durationEnd = try duration.map { try checkedTimeSum(start, $0) }
            let defaultEnd = min(maxTimeMs, start + 2_500)
            let end = max(start + 1, explicitEnd ?? durationEnd ?? defaultEnd)
            let lineID = firstNonEmpty(attribute(paragraph, "key"), attribute(paragraph, "id"), "line-\(index + 1)")
            let agent = attribute(paragraph, "agent")
            addAgent(agent, to: &agentOrder)
            let speaker = presentation(agent, order: agentOrder)
            let lead = try parsePart(paragraph.contents, start: start, end: end, excludingBackground: true)
            var backgrounds: [ProviderVocalPart] = []
            for child in backgroundElements(in: paragraph.contents) {
                let backgroundAgent = firstNonEmpty(attribute(child, "agent"), agent)
                addAgent(backgroundAgent, to: &agentOrder)
                let childStart = try optionalTime(attribute(child, "begin")) ?? start
                guard childStart < maxTimeMs else { throw LyricsProviderError.providerFormat }
                let childEnd = try optionalTime(attribute(child, "end"))
                    ?? (try optionalTime(attribute(child, "dur"))).map { try checkedTimeSum(childStart, $0) }
                    ?? end
                let part = stripParentheses(try parsePart(child.contents,
                    start: childStart, end: childEnd, excludingBackground: false))
                if let vocal = vocalPart(id: "\(lineID)-background-\(backgrounds.count + 1)",
                                         role: .background, part: part,
                                         speaker: presentation(backgroundAgent, order: agentOrder)) {
                    backgrounds.append(vocal)
                }
            }
            var leadPart = vocalPart(id: "\(lineID)-lead", role: .lead, part: lead, speaker: speaker)
            if leadPart == nil, !backgrounds.isEmpty, !lead.text.isEmpty {
                leadPart = ProviderVocalPart(id: "\(lineID)-lead", role: .lead, speaker: speaker,
                    text: lead.text, syllables: [.init(text: lead.text, startMs: start, endMs: end)])
            }
            if leadPart == nil, !backgrounds.isEmpty {
                let promoted = backgrounds.removeFirst()
                leadPart = ProviderVocalPart(id: "\(lineID)-lead", role: .lead,
                    speaker: promoted.speaker, text: promoted.text, syllables: promoted.syllables)
            }
            let backgroundText = backgrounds.map(\.text)
            let displayText = normalize(([lead.text] + backgroundText).filter { !$0.isEmpty }.joined(separator: " "))
            let fallbackText = normalize(textContent(paragraph))
            let text = firstNonEmpty(displayText, fallbackText)
            guard !text.isEmpty else { continue }
            let parts = ([leadPart].compactMap { $0 } + backgrounds)
            syllableCount += backgrounds.isEmpty
                ? lead.syllables.count
                : parts.reduce(0) { $0 + $1.syllables.count }
            guard syllableCount <= maxSyllables else { throw LyricsProviderError.providerFormat }
            let hasBackground = !backgrounds.isEmpty
            let lineSyllables = hasBackground ? [] : lead.syllables
            let lineParts = hasBackground ? parts : []
            let resolvedStart = parts.flatMap(\.syllables).map(\.startMs).min() ?? start
            let resolvedEnd = parts.flatMap(\.syllables).map(\.endMs).max() ?? end
            lines.append(ProviderLyricLine(startMs: resolvedStart, endMs: max(resolvedStart + 1, resolvedEnd),
                text: text, syllables: lineSyllables, speaker: speaker, vocalParts: lineParts))
        }
        guard !lines.isEmpty else { throw LyricsProviderError.miss }
        lines = lines.enumerated().sorted { left, right in
            left.element.startMs == right.element.startMs
                ? left.offset < right.offset
                : left.element.startMs < right.element.startMs
        }.map(\.element)
        return UnisonParsedLyrics(lines: lines, timing: .lineSynced)
    }

    private struct ParsedPart {
        var text: String
        var syllables: [ProviderLyricSyllable]
    }

    private static func parsePart(_ contents: [XMLContent], start: Int64, end: Int64,
                                  excludingBackground: Bool, depth: Int = 0) throws -> ParsedPart {
        guard depth <= maxXMLDepth else { throw LyricsProviderError.providerFormat }
        var text = "", syllables: [ProviderLyricSyllable] = []
        for content in contents {
            switch content {
            case .text(let raw): try append(raw, timed: false, start: start, end: end, text: &text, syllables: &syllables)
            case .element(let node):
                if excludingBackground && attribute(node, "role").lowercased() == "x-bg" { continue }
                if localName(node.name) == "br" { try append(" ", timed: false, start: start, end: end, text: &text, syllables: &syllables); continue }
                let nodeStart = try optionalTime(attribute(node, "begin")) ?? start
                guard nodeStart < maxTimeMs else { throw LyricsProviderError.providerFormat }
                let nodeEnd = try optionalTime(attribute(node, "end"))
                    ?? (try optionalTime(attribute(node, "dur"))).map { try checkedTimeSum(nodeStart, $0) }
                    ?? end
                if childElements(node.contents).isEmpty {
                    let timed = !attribute(node, "begin").isEmpty || !attribute(node, "end").isEmpty || !attribute(node, "dur").isEmpty
                    try append(textContent(node), timed: timed, start: nodeStart, end: nodeEnd,
                               text: &text, syllables: &syllables)
                } else {
                    let nested = try parsePart(node.contents, start: nodeStart, end: nodeEnd,
                                               excludingBackground: excludingBackground, depth: depth + 1)
                    text += nested.text
                    syllables += nested.syllables
                }
            }
        }
        return ParsedPart(text: normalize(text), syllables: syllables.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static func append(_ raw: String, timed: Bool, start: Int64, end: Int64,
                               text: inout String, syllables: inout [ProviderLyricSyllable]) throws {
        var value = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if text.isEmpty { value = String(value.drop(while: \.isWhitespace)) }
        if text.last == " ", value.first == " " { value.removeFirst() }
        guard !value.isEmpty else { return }
        text += value
        if timed {
            guard start >= 0, start < maxTimeMs else { throw LyricsProviderError.providerFormat }
            let safeStart = start
            syllables.append(.init(text: value, startMs: safeStart, endMs: max(safeStart + 1, end)))
        }
    }

    private static func vocalPart(id: String, role: ProviderVocalRole, part: ParsedPart,
                                  speaker: ProviderSpeakerPresentation?) -> ProviderVocalPart? {
        guard !part.text.isEmpty, !part.syllables.isEmpty else { return nil }
        return ProviderVocalPart(id: id, role: role, speaker: speaker,
                                 text: part.text, syllables: part.syllables)
    }

    private static func stripParentheses(_ part: ParsedPart) -> ParsedPart {
        ParsedPart(text: normalize(part.text.replacingOccurrences(of: #"[()（）]"#, with: "", options: .regularExpression)),
            syllables: part.syllables.compactMap {
                let text = $0.text.replacingOccurrences(of: #"[()（）]"#, with: "", options: .regularExpression)
                return text.isEmpty ? nil : ProviderLyricSyllable(text: text, startMs: $0.startMs, endMs: $0.endMs)
            })
    }

    private static func presentation(_ agent: String, order: [String: Int]) -> ProviderSpeakerPresentation? {
        guard !agent.isEmpty else { return nil }
        let index = max(0, order[agent] ?? 0)
        return index == 0 ? ProviderSpeakerPresentation(speaker: "NORMAL") : palette[(index - 1) % palette.count]
    }

    private static func addAgent(_ agent: String, to order: inout [String: Int]) {
        if !agent.isEmpty, order[agent] == nil { order[agent] = order.count }
    }

    private static func optionalTime(_ raw: String) throws -> Int64? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let match = value.firstMatch(#"^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(ms|h|m|s)$"#),
           let amount = Double(match[1]) {
            let multiplier: Double = ["h": 3_600_000, "m": 60_000, "s": 1_000][match[2].lowercased()] ?? 1
            return try validatedMilliseconds(amount * multiplier)
        }
        let rawParts = value.split(separator: ":", omittingEmptySubsequences: false)
        let parts = rawParts.compactMap { Double($0) }
        guard parts.count == rawParts.count, (1...3).contains(parts.count),
              parts.allSatisfy(\.isFinite) else { throw LyricsProviderError.providerFormat }
        if parts.count >= 2, !(0..<60).contains(parts[parts.count - 1]) {
            throw LyricsProviderError.providerFormat
        }
        if parts.count == 3, !(0..<60).contains(parts[1]) {
            throw LyricsProviderError.providerFormat
        }
        let seconds = parts.count == 3 ? parts[0] * 3_600 + parts[1] * 60 + parts[2]
            : (parts.count == 2 ? parts[0] * 60 + parts[1] : parts[0])
        return try validatedMilliseconds(seconds * 1_000)
    }

    private static func validatedMilliseconds(_ value: Double) throws -> Int64 {
        guard value.isFinite, value >= 0, value <= Double(maxTimeMs) else {
            throw LyricsProviderError.providerFormat
        }
        return Int64(value.rounded())
    }

    private static func checkedTimeSum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        guard let result = added(lhs, rhs), result <= maxTimeMs else {
            throw LyricsProviderError.providerFormat
        }
        return result
    }

    private static func declareMissingNamespaces(_ xml: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<tt\b[^>]*>"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range, in: xml) else { return xml }
        let root = String(xml[range])
        var declared = Set(["xml", "xmlns"]), used = Set<String>()
        for values in root.matches(#"xmlns:([A-Za-z][\w.-]*)\s*="#) { declared.insert(values[1]) }
        for values in xml.matches(#"</?([A-Za-z][\w.-]*):"#) { used.insert(values[1]) }
        for values in xml.matches(#"\s([A-Za-z][\w.-]*):[\w.-]+\s*="#) { used.insert(values[1]) }
        let additions = used.subtracting(declared).sorted().map { " xmlns:\($0)=\"urn:ivlyrics:unison:\($0)\"" }.joined()
        guard !additions.isEmpty else { return xml }
        return xml.replacingCharacters(in: range, with: String(root.dropLast()) + additions + ">")
    }

    private static func elements(named name: String, roots: [XMLNode]) -> [XMLNode] {
        var result: [XMLNode] = []
        var pending = Array(roots.reversed())
        while let node = pending.popLast() {
            if localName(node.name) == name { result.append(node) }
            pending.append(contentsOf: childElements(node.contents).reversed())
        }
        return result
    }
    private static func backgroundElements(in contents: [XMLContent]) -> [XMLNode] {
        var result: [XMLNode] = []
        var pending = Array(childElements(contents).reversed())
        while let node = pending.popLast() {
            if attribute(node, "role").lowercased() == "x-bg" {
                result.append(node)
            } else {
                pending.append(contentsOf: childElements(node.contents).reversed())
            }
        }
        return result
    }
    private static func childElements(_ contents: [XMLContent]) -> [XMLNode] {
        contents.compactMap { if case .element(let node) = $0 { return node }; return nil }
    }
    private static func attribute(_ node: XMLNode, _ name: String) -> String {
        node.attributes[name] ?? node.attributes.first { localName($0.key) == name }?.value ?? ""
    }
    private static func localName(_ value: String) -> String { value.split(separator: ":").last.map(String.init) ?? value }
    private static func textContent(_ node: XMLNode) -> String {
        var result = ""
        var pending = Array(node.contents.reversed())
        while let content = pending.popLast() {
            switch content {
            case .text(let text): result += text
            case .element(let child): pending.append(contentsOf: child.contents.reversed())
            }
        }
        return result
    }
    private static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }
    private static func stripBOM(_ value: String) -> String { value.first == "\u{FEFF}" ? String(value.dropFirst()) : value }
    private static func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
    private static func validateLineCount(_ source: String) throws {
        var count = 1
        var previousWasCarriageReturn = false
        for scalar in source.unicodeScalars {
            let isCarriageReturn = scalar.value == 0x0D
            let isLineFeed = scalar.value == 0x0A
            let isOtherNewline = scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029
            if isCarriageReturn || (isLineFeed && !previousWasCarriageReturn) || isOtherNewline {
                count += 1
                if count > maxLines { throw LyricsProviderError.providerFormat }
            }
            previousWasCarriageReturn = isCarriageReturn
        }
    }
    private static func multiplied(_ lhs: Int64, by rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }
    private static func added(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }
    private static func absSafely(_ value: Int64) -> Int64 {
        value == .min ? .max : Swift.abs(value)
    }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var contents: [XMLContent] = []
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
}
private indirect enum XMLContent { case text(String), element(XMLNode) }
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    enum Failure { case depth, nodes, text }
    var roots: [XMLNode] = []
    private(set) var failure: Failure?
    private(set) var wasCancelled = false
    private var stack: [XMLNode] = []
    private let maxDepth: Int
    private let maxNodes: Int
    private let maxTextCharacters: Int
    private let eventObserver: (() -> Void)?
    private var nodeCount = 0
    private var textCharacterCount = 0

    init(maxDepth: Int, maxNodes: Int, maxTextCharacters: Int, eventObserver: (() -> Void)?) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxTextCharacters = maxTextCharacters
        self.eventObserver = eventObserver
    }

    private func shouldAbort(_ parser: XMLParser) -> Bool {
        if Task.isCancelled {
            wasCancelled = true
            parser.abortParsing()
            return true
        }
        return failure != nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !shouldAbort(parser) else { return }
        eventObserver?()
        guard !shouldAbort(parser) else { return }
        nodeCount += 1
        guard stack.count < maxDepth else { failure = .depth; parser.abortParsing(); return }
        guard nodeCount <= maxNodes else { failure = .nodes; parser.abortParsing(); return }
        let node = XMLNode(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last { parent.contents.append(.element(node)) } else { roots.append(node) }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !shouldAbort(parser) else { return }
        appendText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !shouldAbort(parser) else { return }
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            failure = .text
            parser.abortParsing()
            return
        }
        appendText(string, parser: parser)
    }

    private func appendText(_ string: String, parser: XMLParser) {
        let (count, overflow) = textCharacterCount.addingReportingOverflow(string.count)
        guard !overflow, count <= maxTextCharacters else {
            failure = .text
            parser.abortParsing()
            return
        }
        textCharacterCount = count
        stack.last?.contents.append(.text(string))
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !shouldAbort(parser) else { return }
        if !stack.isEmpty { stack.removeLast() }
    }
}

private extension String {
    func matches(_ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
    func firstMatch(_ pattern: String) -> [String]? { matches(pattern).first }
}
