import Foundation

struct TrackSnapshot: Equatable, Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    var packageName: String
    var mediaId: String
    var isrc: String
    var durationMs: Int64
    var positionMs: Int64
    var lastPositionUpdate: Date
    var lastPositionUpdateUptime: TimeInterval
    var playbackSpeed: Double
    var playing: Bool
    var artworkURL: URL?

    var trackId: String {
        Self.extractSpotifyTrackId(mediaId)
    }

    init(
        title: String,
        artist: String,
        album: String = "",
        packageName: String = "ios.manual",
        mediaId: String = "",
        isrc: String = "",
        durationMs: Int64 = 0,
        positionMs: Int64 = 0,
        lastPositionUpdate: Date = Date(),
        lastPositionUpdateUptime: TimeInterval? = nil,
        playbackSpeed: Double = 1,
        playing: Bool = false,
        artworkURL: URL? = nil
    ) {
        self.title = title.trimmed
        self.artist = artist.trimmed
        self.album = album.trimmed
        self.packageName = packageName.trimmed
        self.mediaId = Self.normalizedSpotifyMediaId(mediaId)
        self.isrc = Self.normalizeIsrc(isrc)
        self.durationMs = max(0, durationMs)
        self.positionMs = max(0, positionMs)
        self.lastPositionUpdate = lastPositionUpdate
        let uptimeNow = ProcessInfo.processInfo.systemUptime
        self.lastPositionUpdateUptime = lastPositionUpdateUptime
            ?? max(0, uptimeNow - max(0, Date().timeIntervalSince(lastPositionUpdate)))
        self.playbackSpeed = playbackSpeed > 0 ? playbackSpeed : 1
        self.playing = playing
        self.artworkURL = artworkURL
    }

    var hasUsableMetadata: Bool {
        !title.isEmpty && !artist.isEmpty
    }

    var isSpotifyDjSegment: Bool {
        sameMetadata(artist, "DJ X") && (sameMetadata(title, "Welcome") || sameMetadata(title, "Up Next"))
    }

    var stableKey: String {
        if !trackId.isEmpty {
            return "spotify:\(trackId)"
        }
        return "\(Self.normalizeForKey(title))|\(Self.normalizeForKey(artist))|\(durationMs)"
    }

    func positionNow(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int64 {
        guard playing else {
            return clampPosition(positionMs)
        }
        let elapsed = max(0, uptime - lastPositionUpdateUptime) * 1000
        return clampPosition(positionMs + Int64((elapsed * playbackSpeed).rounded()))
    }

    func withPlayback(
        positionMs: Int64,
        playing: Bool,
        date: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TrackSnapshot {
        var copy = self
        copy.positionMs = max(0, positionMs)
        copy.playing = playing
        copy.lastPositionUpdate = date
        copy.lastPositionUpdateUptime = uptime
        return copy
    }

    static func == (lhs: TrackSnapshot, rhs: TrackSnapshot) -> Bool {
        lhs.durationMs == rhs.durationMs
            && lhs.playing == rhs.playing
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.packageName == rhs.packageName
            && lhs.mediaId == rhs.mediaId
            && lhs.artworkURL == rhs.artworkURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(artist)
        hasher.combine(album)
        hasher.combine(packageName)
        hasher.combine(mediaId)
        hasher.combine(durationMs)
        hasher.combine(playing)
        hasher.combine(artworkURL)
    }

    private func clampPosition(_ value: Int64) -> Int64 {
        if durationMs > 0 {
            return max(0, min(durationMs, value))
        }
        return max(0, value)
    }

    static func normalizeIsrc(_ value: String?) -> String {
        let normalized = (value ?? "")
            .replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression)
            .uppercased()
            .trimmed
        return normalized.range(of: #"^[A-Z]{2}[A-Z0-9]{3}\d{7}$"#, options: .regularExpression) == nil ? "" : normalized
    }

    static func extractSpotifyTrackId(_ value: String?) -> String {
        let text = (value ?? "").trimmed
        let pattern = #"(?:spotify:track:|open\.spotify\.com/track/)([A-Za-z0-9]{22})"#
        guard let match = text.range(of: pattern, options: .regularExpression) else {
            return text.range(of: #"^[A-Za-z0-9]{22}$"#, options: .regularExpression) == nil ? "" : text
        }
        let raw = String(text[match])
        if let idRange = raw.range(of: #"[A-Za-z0-9]{22}"#, options: .regularExpression) {
            return String(raw[idRange])
        }
        return ""
    }

    static func normalizedSpotifyMediaId(_ value: String?) -> String {
        let text = (value ?? "").trimmed
        let spotifyId = extractSpotifyTrackId(text)
        return spotifyId.isEmpty ? text : "spotify:track:\(spotifyId)"
    }

    private static func normalizeForKey(_ value: String) -> String {
        value.trimmed.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func sameMetadata(_ lhs: String, _ rhs: String) -> Bool {
        Self.normalizeForKey(lhs) == Self.normalizeForKey(rhs)
    }
}

struct LyricsLine: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var startTimeMs: Int64
    var endTimeMs: Int64
    var text: String
    var syllables: [Syllable]
    var speaker: String
    var speakerColor: String
    var speakerFallback: String
    var kind: String
    var vocalParts: [VocalPart]
    var pronunciationText: String
    var translationText: String
    var furiganaText: String

    init(
        startTimeMs: Int64,
        endTimeMs: Int64,
        text: String,
        syllables: [Syllable] = [],
        speaker: String = "",
        speakerColor: String = "",
        speakerFallback: String = "",
        kind: String = "vocal",
        vocalParts: [VocalPart] = [],
        pronunciationText: String = "",
        translationText: String = "",
        furiganaText: String = ""
    ) {
        self.startTimeMs = max(0, startTimeMs)
        self.endTimeMs = max(max(0, startTimeMs), endTimeMs)
        self.text = text
        self.syllables = syllables
        self.speaker = speaker
        self.speakerColor = speakerColor
        self.speakerFallback = speakerFallback
        self.kind = kind.trimmed.isEmpty ? "vocal" : kind.trimmed
        self.vocalParts = vocalParts
        self.pronunciationText = pronunciationText
        self.translationText = translationText
        self.furiganaText = furiganaText
    }

    var isTimed: Bool {
        startTimeMs > 0 || endTimeMs > startTimeMs
    }

    func withSupplements(pronunciation: String, translation: String, furigana: String? = nil) -> LyricsLine {
        LyricsLine(
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs,
            text: text,
            syllables: syllables,
            speaker: speaker,
            speakerColor: speakerColor,
            speakerFallback: speakerFallback,
            kind: kind,
            vocalParts: vocalParts,
            pronunciationText: pronunciation,
            translationText: translation,
            furiganaText: furigana ?? furiganaText
        )
    }

    struct Syllable: Codable, Equatable, Sendable {
        var text: String
        var startTimeMs: Int64
        var endTimeMs: Int64

        init(text: String, startTimeMs: Int64, endTimeMs: Int64) {
            self.text = text
            self.startTimeMs = max(0, startTimeMs)
            self.endTimeMs = max(max(0, startTimeMs), endTimeMs)
        }
    }

    struct VocalPart: Identifiable, Codable, Equatable, Sendable {
        var id: String
        var role: String
        var speaker: String
        var speakerColor: String
        var speakerFallback: String
        var kind: String
        var text: String
        var syllables: [Syllable]
        var pronunciationText: String
        var translationText: String
        var furiganaText: String

        var startTimeMs: Int64 {
            syllables.first?.startTimeMs ?? 0
        }

        var endTimeMs: Int64 {
            syllables.last?.endTimeMs ?? startTimeMs
        }

        init(
            id: String,
            role: String,
            speaker: String,
            speakerColor: String = "",
            speakerFallback: String = "",
            kind: String,
            text: String,
            syllables: [Syllable],
            pronunciationText: String = "",
            translationText: String = "",
            furiganaText: String = ""
        ) {
            self.id = id
            self.role = role
            self.speaker = speaker
            self.speakerColor = speakerColor
            self.speakerFallback = speakerFallback
            self.kind = kind.trimmed.isEmpty ? "vocal" : kind.trimmed
            self.text = text
            self.syllables = syllables
            self.pronunciationText = pronunciationText
            self.translationText = translationText
            self.furiganaText = furiganaText
        }

        func withSupplements(pronunciation: String, translation: String, furigana: String? = nil) -> VocalPart {
            VocalPart(
                id: id,
                role: role,
                speaker: speaker,
                speakerColor: speakerColor,
                speakerFallback: speakerFallback,
                kind: kind,
                text: text,
                syllables: syllables,
                pronunciationText: pronunciation,
                translationText: translation,
                furiganaText: furigana ?? furiganaText
            )
        }

        private enum CodingKeys: String, CodingKey {
            case id, role, speaker, speakerColor, speakerFallback, kind, text, syllables
            case pronunciationText, translationText, furiganaText
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
            speaker = try container.decodeIfPresent(String.self, forKey: .speaker) ?? ""
            speakerColor = try container.decodeIfPresent(String.self, forKey: .speakerColor) ?? ""
            speakerFallback = try container.decodeIfPresent(String.self, forKey: .speakerFallback) ?? ""
            let decodedKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "vocal"
            kind = decodedKind.trimmed.isEmpty ? "vocal" : decodedKind.trimmed
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            syllables = try container.decodeIfPresent([Syllable].self, forKey: .syllables) ?? []
            pronunciationText = try container.decodeIfPresent(String.self, forKey: .pronunciationText) ?? ""
            translationText = try container.decodeIfPresent(String.self, forKey: .translationText) ?? ""
            furiganaText = try container.decodeIfPresent(String.self, forKey: .furiganaText) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(role, forKey: .role)
            try container.encode(speaker, forKey: .speaker)
            try container.encode(speakerColor, forKey: .speakerColor)
            try container.encode(speakerFallback, forKey: .speakerFallback)
            try container.encode(kind, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(syllables, forKey: .syllables)
            try container.encode(pronunciationText, forKey: .pronunciationText)
            try container.encode(translationText, forKey: .translationText)
            try container.encode(furiganaText, forKey: .furiganaText)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, startTimeMs, endTimeMs, text, syllables, speaker, speakerColor, speakerFallback, kind, vocalParts
        case pronunciationText, translationText, furiganaText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedStart = try container.decodeIfPresent(Int64.self, forKey: .startTimeMs) ?? 0
        startTimeMs = max(0, decodedStart)
        endTimeMs = max(startTimeMs, try container.decodeIfPresent(Int64.self, forKey: .endTimeMs) ?? startTimeMs)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        syllables = try container.decodeIfPresent([Syllable].self, forKey: .syllables) ?? []
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        speakerColor = try container.decodeIfPresent(String.self, forKey: .speakerColor) ?? ""
        speakerFallback = try container.decodeIfPresent(String.self, forKey: .speakerFallback) ?? ""
        let decodedKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "vocal"
        kind = decodedKind.trimmed.isEmpty ? "vocal" : decodedKind.trimmed
        vocalParts = try container.decodeIfPresent([VocalPart].self, forKey: .vocalParts) ?? []
        pronunciationText = try container.decodeIfPresent(String.self, forKey: .pronunciationText) ?? ""
        translationText = try container.decodeIfPresent(String.self, forKey: .translationText) ?? ""
        furiganaText = try container.decodeIfPresent(String.self, forKey: .furiganaText) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startTimeMs, forKey: .startTimeMs)
        try container.encode(endTimeMs, forKey: .endTimeMs)
        try container.encode(text, forKey: .text)
        try container.encode(syllables, forKey: .syllables)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(speakerColor, forKey: .speakerColor)
        try container.encode(speakerFallback, forKey: .speakerFallback)
        try container.encode(kind, forKey: .kind)
        try container.encode(vocalParts, forKey: .vocalParts)
        try container.encode(pronunciationText, forKey: .pronunciationText)
        try container.encode(translationText, forKey: .translationText)
        try container.encode(furiganaText, forKey: .furiganaText)
    }
}

struct LyricsResult: Codable, Equatable, Sendable {
    var lines: [LyricsLine]
    var providerLabel: String
    var detail: String
    var karaoke: Bool
    var isrc: String
    var spotifyTrackId: String
    var contributors: [SyncContributor]

    init(
        lines: [LyricsLine],
        providerLabel: String,
        detail: String,
        karaoke: Bool,
        isrc: String = "",
        spotifyTrackId: String = "",
        contributors: [SyncContributor] = []
    ) {
        self.lines = lines
        self.providerLabel = providerLabel
        self.detail = detail
        self.karaoke = karaoke
        self.isrc = TrackSnapshot.normalizeIsrc(isrc)
        self.spotifyTrackId = spotifyTrackId.trimmed
        self.contributors = contributors
    }

    static func empty(_ detail: String) -> LyricsResult {
        LyricsResult(lines: [], providerLabel: "", detail: detail, karaoke: false)
    }

    struct SyncContributor: Codable, Equatable, Hashable, Sendable {
        var name: String
        var userHash: String
        var profileAvailable: Bool

        init(name: String, userHash: String = "", profileAvailable: Bool = false) {
            let safeName = name.trimmed
            let safeHash = userHash.trimmed
            self.name = safeName.isEmpty ? "Anonymous" : safeName
            self.userHash = safeHash
            self.profileAvailable = profileAvailable && !safeHash.isEmpty
        }
    }
}

struct ManualLrclibCandidate: Identifiable, Equatable, Sendable {
    var id: Int64
    var trackName: String
    var artistName: String
    var albumName: String
    var durationSeconds: Double
    var synced: Bool
    var plain: Bool
    var instrumental: Bool
    var isrc: String
    var score: Double
}

struct YouTubeVideoInfo: Codable, Equatable, Sendable {
    var isrc: String
    var spotifyTrackId: String
    var youtubeVideoId: String
    var youtubeTitle: String
    var hasCaptionStartTime: Bool
    var captionStartTimeSeconds: Double
    var autoGenerated: Bool
    var submitterId: String

    var watchURL: URL? {
        youtubeVideoId.isEmpty ? nil : URL(string: "https://www.youtube.com/watch?v=\(youtubeVideoId)")
    }
}

struct SpotifyResolvedTrack: Equatable, Sendable {
    var spotifyId: String
    var title: String
    var artist: String
    var album: String
    var isrc: String
    var durationMs: Int64
    var artworkURL: URL?
    var logs: [String]
}

struct SpotifyPlaybackSnapshot: Equatable, Sendable {
    var track: TrackSnapshot
    var progressMs: Int64
    var playing: Bool
    var fetchedAt: Date
    var deviceName: String
}

struct SpotifyPlaybackInteractionGuard {
    private struct PlaybackIntent {
        var trackKey: String
        var playing: Bool
        var issuedAtUptime: TimeInterval
    }

    private struct SeekIntent {
        var trackKey: String
        var positionMs: Int64
        var issuedAtUptime: TimeInterval
    }

    private var playbackIntent: PlaybackIntent?
    private var seekIntent: SeekIntent?

    private let playbackHoldSeconds: TimeInterval = 2.0
    private let seekHoldSeconds: TimeInterval = 2.5
    private let seekAcknowledgementToleranceMs: Int64 = 2_500

    mutating func registerPlayback(trackKey: String, playing: Bool, uptime: TimeInterval) {
        playbackIntent = PlaybackIntent(
            trackKey: trackKey,
            playing: playing,
            issuedAtUptime: uptime
        )
    }

    mutating func registerSeek(trackKey: String, positionMs: Int64, uptime: TimeInterval) {
        seekIntent = SeekIntent(
            trackKey: trackKey,
            positionMs: max(0, positionMs),
            issuedAtUptime: uptime
        )
    }

    mutating func reset() {
        playbackIntent = nil
        seekIntent = nil
    }

    mutating func reconcile(
        _ snapshot: SpotifyPlaybackSnapshot,
        currentTrack: TrackSnapshot?,
        uptime: TimeInterval
    ) -> SpotifyPlaybackSnapshot {
        guard let currentTrack,
              currentTrack.stableKey == snapshot.track.stableKey else {
            reset()
            return snapshot
        }

        var positionMs = snapshot.progressMs
        var playing = snapshot.playing
        var preservedOptimisticState = false
        let optimisticPositionMs = currentTrack.positionNow(uptime: uptime)

        if let intent = playbackIntent {
            if intent.trackKey != snapshot.track.stableKey {
                playbackIntent = nil
            } else if snapshot.playing == intent.playing {
                playbackIntent = nil
            } else if uptime - intent.issuedAtUptime <= playbackHoldSeconds {
                playing = intent.playing
                positionMs = optimisticPositionMs
                preservedOptimisticState = true
            } else {
                playbackIntent = nil
            }
        }

        if let intent = seekIntent {
            if intent.trackKey != snapshot.track.stableKey {
                seekIntent = nil
            } else if abs(snapshot.progressMs - intent.positionMs) <= seekAcknowledgementToleranceMs
                        || abs(snapshot.progressMs - optimisticPositionMs) <= seekAcknowledgementToleranceMs {
                seekIntent = nil
            } else if uptime - intent.issuedAtUptime <= seekHoldSeconds {
                positionMs = optimisticPositionMs
                preservedOptimisticState = true
            } else {
                seekIntent = nil
            }
        }

        guard preservedOptimisticState
                || positionMs != snapshot.progressMs
                || playing != snapshot.playing else {
            return snapshot
        }
        let reconciledTrack = snapshot.track.withPlayback(
            positionMs: positionMs,
            playing: playing,
            uptime: uptime
        )
        return SpotifyPlaybackSnapshot(
            track: reconciledTrack,
            progressMs: positionMs,
            playing: playing,
            fetchedAt: snapshot.fetchedAt,
            deviceName: snapshot.deviceName
        )
    }
}

enum AppStatus: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case setupRequired
    case failed(String)

    func text(settings: AppSettings) -> String {
        switch self {
        case .idle:
            return settings.t("status.idle")
        case .loading:
            return settings.t("status.lyrics_loading")
        case .loaded:
            return settings.t("status.loaded")
        case .setupRequired:
            return settings.t("status.spotify_required_plain")
        case .failed(let message):
            return message
        }
    }
}
