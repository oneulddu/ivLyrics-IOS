import Foundation

public final class LrclibProviderAdapter: LyricsProviderDirectPreflighting, @unchecked Sendable {
    public let id: LyricsProviderID = .lrclib
    private let http: ProviderHTTPClient
    private let baseURL: URL

    public init(httpClient: ProviderHTTPClient = ProviderHTTPClient(),
                baseURL: URL = URL(string: "https://lrclib.net/api")!) {
        self.http = httpClient
        self.baseURL = baseURL
    }

    public func fetchDirect(_ request: LyricsProviderRequest,
                            providerTrackID: String) async throws -> ProviderLyrics {
        guard let id = Int64(providerTrackID), id > 0 else { throw LyricsProviderError.miss }
        let response = try await http.get(endpoint("get/\(id)"))
        let item: APIItem = try http.decodeJSON(APIItem.self, from: response)
        guard item.id == id else { throw LyricsProviderError.providerFormat }
        return try makeLyrics(item, request: request, forceDirect: true)
    }

    public func fetch(_ request: LyricsProviderRequest) async throws -> ProviderLyrics {
        if let directID = request.syncDataSelectionContext?.lrclibID, directID > 0 {
            do { return try await fetchDirect(request, providerTrackID: String(directID)) }
            catch let error as LyricsProviderError where error == .miss || error == .providerFormat { }
        }
        var items = try await search(request: request, queryOnly: false)
        var selected = select(items, request: request)
        if selected == nil {
            let fallback = try await search(request: request, queryOnly: true)
            var seen = Set(items.map(\.id))
            items.append(contentsOf: fallback.filter { seen.insert($0.id).inserted })
            selected = select(items, request: request)
        }
        guard let selected else { throw LyricsProviderError.miss }
        return try makeLyrics(selected.item, request: request, forceDirect: false,
                              preferredSource: selected.preferredSource,
                              evidenceOverride: selected.evidence)
    }

    private func search(request: LyricsProviderRequest, queryOnly: Bool) async throws -> [APIItem] {
        let query: [URLQueryItem]
        if queryOnly {
            query = [URLQueryItem(name: "q", value: [request.title, request.artist]
                .filter { !$0.isEmpty }.joined(separator: " "))]
        } else {
            var values = [URLQueryItem(name: "track_name", value: request.title),
                          URLQueryItem(name: "artist_name", value: request.artist)]
            if !request.album.isEmpty { values.append(URLQueryItem(name: "album_name", value: request.album)) }
            query = values
        }
        let response = try await http.get(endpoint("search"), queryItems: query)
        return try http.decodeJSON([APIItem].self, from: response)
    }

    private struct Decorated {
        let item: APIItem
        let evidence: MatchEvidence
        let sourceScore: Int
        let exactSynced: Bool
        let exactPlain: Bool
        let hasOriginalScript: Bool
        let preferredSource: String
        var contextMatch: Bool { sourceScore > 0 || exactSynced || exactPlain }
    }

    private func select(_ items: [APIItem], request: LyricsProviderRequest) -> Decorated? {
        items.compactMap { decorate($0, request: request) }
            .sorted(by: compareDecorated)
            .first(where: { $0.contextMatch || LyricsMatcher.accepts($0.evidence,
                directIdentifier: $0.evidence.directIdentifier) })
    }

    private func decorate(_ item: APIItem, request: LyricsProviderRequest) -> Decorated? {
        guard !item.instrumental else { return nil }
        let preliminary = candidate(item, request: request, evidence: placeholderEvidence())
        let evidence = LyricsMatcher.score(request: request, candidate: preliminary)
        guard item.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || item.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        guard let context = request.syncDataSelectionContext else {
            return Decorated(item: item, evidence: evidence, sourceScore: 0,
                             exactSynced: false, exactPlain: false, hasOriginalScript: false,
                             preferredSource: item.syncedLyrics == nil ? "plain" : "synced")
        }
        let syncedCounts = counts(item.syncedLyrics, stripTimestamps: true, context: context)
        let plainCounts = counts(item.plainLyrics, stripTimestamps: false, context: context)
        let exactSynced = !context.lineCharCounts.isEmpty && context.lineCharCounts == syncedCounts
        let exactPlain = !context.lineCharCounts.isEmpty && context.lineCharCounts == plainCounts
        var preferred = exactSynced ? "synced" : (exactPlain ? "plain" : context.preferredLyricsSource)
        let sourceSynced = !context.sourceLineCharCounts.isEmpty && context.sourceLineCharCounts == syncedCounts
        let sourcePlain = !context.sourceLineCharCounts.isEmpty && context.sourceLineCharCounts == plainCounts
        if preferred.isEmpty { preferred = sourceSynced ? "synced" : (sourcePlain ? "plain" : context.preferredLyricsSource) }
        let comparable = comparableText(item, preferredSource: preferred, context: context)
        let idMatch = context.hasLrclibSource && context.lrclibID > 0 && item.id == context.lrclibID
        let textMatch = context.hasLrclibSource && !context.sourceLyricsFingerprint.isEmpty
            && LyricsTextNormalizer.lyricsFingerprint(comparable) == context.sourceLyricsFingerprint
        let shapeMatch = context.hasLrclibSource && !context.sourceLineCharCounts.isEmpty
            && context.sourceLineCharCounts == LyricsTextNormalizer.lineCharCounts(
                LyricsTextNormalizer.comparableLyricsLines(comparable, stripTimestamps: false))
        let score = idMatch ? 100 : (textMatch ? 90 : (shapeMatch ? 60 : 0))
        return Decorated(item: item, evidence: evidence, sourceScore: score,
                         exactSynced: exactSynced, exactPlain: exactPlain,
                         hasOriginalScript: LyricsTextNormalizer.hasOriginalLyricsScript(comparable),
                         preferredSource: preferred)
    }

    private func compareDecorated(_ left: Decorated, _ right: Decorated) -> Bool {
        if left.sourceScore != right.sourceScore { return left.sourceScore > right.sourceScore }
        let lg = legacyGroup(left), rg = legacyGroup(right)
        if lg != rg { return lg > rg }
        if left.evidence.totalScore != right.evidence.totalScore {
            return left.evidence.totalScore > right.evidence.totalScore
        }
        return left.item.id < right.item.id
    }

    private func legacyGroup(_ value: Decorated) -> Int {
        if value.hasOriginalScript && value.exactSynced { return 4 }
        if value.hasOriginalScript && value.exactPlain { return 3 }
        if value.exactSynced { return 2 }
        return value.exactPlain ? 1 : 0
    }

    private func makeLyrics(_ item: APIItem, request: LyricsProviderRequest, forceDirect: Bool,
                            preferredSource: String? = nil,
                            evidenceOverride: MatchEvidence? = nil) throws -> ProviderLyrics {
        guard !item.instrumental else { throw LyricsProviderError.miss }
        let source = preferredSource ?? request.syncDataSelectionContext?.preferredLyricsSource ?? ""
        let useSynced = source == "synced"
            ? item.syncedLyrics?.isEmpty == false
            : (source != "plain" && item.syncedLyrics?.isEmpty == false)
        let lines: [ProviderLyricLine]
        let timing: LyricsTiming
        if useSynced, let synced = item.syncedLyrics {
            lines = try ProviderLRC.parse(synced, durationMs: item.duration.map { Int64(($0 * 1_000).rounded()) })
            timing = .lineSynced
        } else if let plain = item.plainLyrics {
            lines = ProviderLRC.splitPlainText(plain)
            timing = .plain
        } else if let synced = item.syncedLyrics {
            lines = try ProviderLRC.parse(synced, durationMs: item.duration.map { Int64(($0 * 1_000).rounded()) })
            timing = .lineSynced
        } else { throw LyricsProviderError.miss }
        guard !lines.isEmpty else { throw LyricsProviderError.miss }
        var provisional = candidate(item, request: request, evidence: placeholderEvidence(), timing: timing)
        var evidence = evidenceOverride ?? LyricsMatcher.score(request: request, candidate: provisional)
        if forceDirect && request.syncDataSelectionContext?.lrclibID == item.id {
            evidence = MatchEvidence(titleScore: evidence.titleScore, artistScore: evidence.artistScore,
                                     durationScore: evidence.durationScore,
                                     durationDeltaMs: evidence.durationDeltaMs,
                                     versionPenalty: evidence.versionPenalty,
                                     directIdentifier: .syncDataLrclibID,
                                     totalScore: evidence.totalScore,
                                     policyVersion: evidence.policyVersion)
        }
        provisional = candidate(item, request: request, evidence: evidence, timing: timing)
        return ProviderLyrics(provider: .lrclib, providerTrackID: String(item.id), lines: lines,
                              timing: timing, matchedCandidate: provisional)
    }

    private func candidate(_ item: APIItem, request: LyricsProviderRequest, evidence: MatchEvidence,
                           timing: LyricsTiming? = nil) -> LyricsCandidate {
        var timings = Set<LyricsTiming>()
        if item.syncedLyrics?.isEmpty == false { timings.insert(.lineSynced) }
        if item.plainLyrics?.isEmpty == false { timings.insert(.plain) }
        if let timing { timings.insert(timing) }
        return LyricsCandidate(provider: .lrclib, providerTrackID: String(item.id),
                               title: item.trackName, artist: item.artistName,
                               album: item.albumName, durationMs: item.duration.map { Int64(($0 * 1_000).rounded()) },
                               availableTiming: timings, matchEvidence: evidence)
    }

    private func counts(_ text: String?, stripTimestamps: Bool,
                        context: SyncDataSelectionContext) -> [Int] {
        LyricsTextNormalizer.lineCharCounts(LyricsTextNormalizer.comparableLyricsLines(
            text, stripTimestamps: stripTimestamps,
            normalizeParentheticalLines: context.shouldNormalizeParentheticalLines))
    }

    private func comparableText(_ item: APIItem, preferredSource: String,
                                context: SyncDataSelectionContext) -> String {
        let useSynced = preferredSource == "synced"
            ? item.syncedLyrics != nil
            : (preferredSource != "plain" && item.plainLyrics == nil && item.syncedLyrics != nil)
        let text = useSynced ? LyricsTextNormalizer.stripLrcTimestamps(item.syncedLyrics)
            : firstNonEmpty(item.plainLyrics, LyricsTextNormalizer.stripLrcTimestamps(item.syncedLyrics))
        return LyricsTextNormalizer.joinLinesForFingerprint(LyricsTextNormalizer.comparableLyricsLines(
            text, stripTimestamps: false,
            normalizeParentheticalLines: context.shouldNormalizeParentheticalLines))
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private func endpoint(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    private func placeholderEvidence() -> MatchEvidence {
        MatchEvidence(titleScore: 0, artistScore: 0, durationScore: 0,
                      durationDeltaMs: nil, versionPenalty: 0, directIdentifier: .none,
                      totalScore: 0, policyVersion: LyricsMatcher.policyVersion)
    }

    private struct APIItem: Decodable {
        let id: Int64
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double?
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?

        enum CodingKeys: String, CodingKey {
            case id, trackName, artistName, albumName, duration, instrumental, plainLyrics, syncedLyrics
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int64.self, forKey: .id)
            trackName = try c.decode(String.self, forKey: .trackName)
            artistName = try c.decode(String.self, forKey: .artistName)
            albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
            duration = try c.decodeIfPresent(Double.self, forKey: .duration)
            instrumental = try c.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
            plainLyrics = try c.decodeIfPresent(String.self, forKey: .plainLyrics)
            syncedLyrics = try c.decodeIfPresent(String.self, forKey: .syncedLyrics)
        }
    }
}
