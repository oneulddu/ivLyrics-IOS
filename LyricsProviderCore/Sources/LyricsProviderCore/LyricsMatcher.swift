import Foundation

// Portions adapted from oneulddu/musicxmatch-api (MIT), commit 87eb9b4.
public enum LyricsMatcher {
    public static let policyVersion = 1
    private static let versionMarkers: Set<String> = [
        "live", "remix", "mix", "cover", "instrumental", "karaoke", "tribute",
        "acoustic", "remaster", "remastered", "demo", "radio edit", "sped up", "slowed"
    ]

    public static func normalize(_ value: String) -> String {
        let folded = value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars).split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    public static func titleVariants(_ value: String) -> [String] {
        unique([value, removingBracketedSegments(value), removingFeatured(value), baseTitle(value), normalize(value)])
    }

    public static func artistVariants(_ value: String) -> [String] {
        unique([value, removingFeatured(value), splitArtists(value).first ?? value, normalize(value)])
    }

    public static func score(request: LyricsProviderRequest, candidate: LyricsCandidate) -> MatchEvidence {
        let requestTitle = titleParts(request.title)
        let candidateTitle = titleParts(candidate.title)
        let requestArtists = splitArtists(request.artist)
        let candidateArtists = splitArtists(candidate.artist)
        let titleScore = similarity(requestTitle.base, candidateTitle.base)
        let artistScore = bestPairSimilarity(requestArtists, candidateArtists)
        let delta = durationDelta(request.durationMs, candidate.durationMs)
        let durationScore: Double
        if let delta {
            switch delta {
            case 0...1_500: durationScore = 1
            case 1_501...3_000: durationScore = 0.8
            case 3_001...6_000: durationScore = 0.55
            case 6_001...10_000: durationScore = 0.2
            case 10_001...19_999: durationScore = -0.35
            default: durationScore = -1
            }
        } else {
            durationScore = 0
        }
        let extraMarkers = candidateTitle.markers.subtracting(requestTitle.markers)
        let versionPenalty = extraMarkers.isEmpty ? 0 : min(0.55, 0.3 + 0.08 * Double(extraMarkers.count - 1))
        let direct = inferredDirectIdentifier(request: request, candidate: candidate)
        let total = max(0, min(1, titleScore * 0.70 + artistScore * 0.30
                               + durationScore * 0.08 - versionPenalty))
        return MatchEvidence(titleScore: titleScore, artistScore: artistScore,
                             durationScore: durationScore, durationDeltaMs: delta,
                             versionPenalty: versionPenalty, directIdentifier: direct,
                             totalScore: total, policyVersion: policyVersion)
    }

    public static func accepts(_ evidence: MatchEvidence,
                               directIdentifier: DirectIdentifierEvidence? = nil) -> Bool {
        let direct = directIdentifier ?? evidence.directIdentifier
        if direct == .none, let delta = evidence.durationDeltaMs, delta >= 20_000 { return false }
        if evidence.versionPenalty >= 0.30 && direct == .none { return false }
        if direct != .none {
            return evidence.titleScore >= 0.55 && (evidence.artistScore >= 0.30 || evidence.titleScore >= 0.90)
        }
        guard evidence.titleScore >= 0.78, evidence.artistScore >= 0.45 else { return false }
        return evidence.totalScore >= 0.72
    }

    private static func inferredDirectIdentifier(request: LyricsProviderRequest,
                                                 candidate: LyricsCandidate) -> DirectIdentifierEvidence {
        if candidate.provider == .lrclib,
           let id = request.syncDataSelectionContext?.lrclibID, id > 0,
           candidate.providerTrackID == String(id) { return .syncDataLrclibID }
        return .none
    }

    private static func similarity(_ left: String, _ right: String) -> Double {
        let lhs = normalize(left), rhs = normalize(right)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) {
            let ratio = Double(min(lhs.count, rhs.count)) / Double(max(lhs.count, rhs.count))
            return 0.88 + ratio * 0.08
        }
        let a = Set(lhs.split(separator: " ").map(String.init))
        let b = Set(rhs.split(separator: " ").map(String.init))
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        let jaccard = union == 0 ? 0 : Double(intersection) / Double(union)
        let dice = a.count + b.count == 0 ? 0 : Double(2 * intersection) / Double(a.count + b.count)
        let edit = 1 - Double(levenshtein(Array(lhs), Array(rhs))) / Double(max(lhs.count, rhs.count))
        return max(0, min(1, jaccard * 0.30 + dice * 0.30 + edit * 0.40))
    }

    private static func bestPairSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let scores = lhs.map { left in rhs.map { similarity(left, $0) }.max() ?? 0 }
        let best = scores.max() ?? 0
        let coverage = scores.reduce(0, +) / Double(scores.count)
        return best * 0.7 + coverage * 0.3
    }

    private static func splitArtists(_ value: String) -> [String] {
        let stripped = removingFeatured(value)
        return stripped.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #"\s+[x×]\s+"#, with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",&;/"))
            .map(normalize).filter { !$0.isEmpty }
    }

    private static func removingFeatured(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
    }

    private static func removingBracketedSegments(_ value: String) -> String {
        value.replacingOccurrences(of: #"\([^)]*\)|\[[^]]*\]"#, with: " ", options: .regularExpression)
    }

    private static func baseTitle(_ value: String) -> String {
        let noBrackets = removingBracketedSegments(value)
        return noBrackets.components(separatedBy: " - ").first ?? noBrackets
    }

    private static func titleParts(_ value: String) -> (base: String, markers: Set<String>) {
        let normalized = normalize(value)
        var found = Set<String>()
        for marker in versionMarkers where normalized.range(of: #"(?:^|\s)"# + NSRegularExpression.escapedPattern(for: marker) + #"(?:$|\s)"#, options: .regularExpression) != nil {
            found.insert(marker)
        }
        var base = value
        base = base.replacingOccurrences(of: #"(?i)[\(\[][^\)\]]*(?:live|remix|mix|cover|instrumental|karaoke|tribute|acoustic|remaster(?:ed)?|demo|radio edit|sped up|slowed)[^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        base = base.replacingOccurrences(of: #"(?i)\s+-\s+.*(?:live|remix|cover|instrumental|karaoke|tribute|acoustic|remaster(?:ed)?|demo).*$"#, with: "", options: .regularExpression)
        return (normalize(base), found)
    }

    private static func durationDelta(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        guard let lhs, lhs > 0, let rhs, rhs > 0 else { return nil }
        return abs(lhs - rhs)
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1,
                                     previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalize($0)).inserted }
    }
}
