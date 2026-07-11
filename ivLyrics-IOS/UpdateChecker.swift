import Foundation

struct AppUpdateInfo: Equatable, Identifiable, Sendable {
    var id: String { releaseURL.isEmpty ? tag : releaseURL }

    var updateAvailable: Bool
    var currentVersionCode: Int
    var currentVersionName: String
    var latestVersionCode: Int
    var latestVersionName: String
    var tag: String
    var releaseName: String
    var releaseURL: String
    var releaseNotes: String
    var prerelease: Bool
    var assetName: String
    var assetDownloadURL: String
    var assetSize: Int64
    var assetSha256: String

    var latestDisplayVersion: String {
        if !latestVersionName.isEmpty {
            return latestVersionName
        }
        return tag.isEmpty ? releaseName : tag
    }
}

final class UpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/ivLis-Studio/ivLyrics-IOS/releases/latest")!

    func checkLatest() async throws -> AppUpdateInfo {
        let release = try await jsonObject(from: Self.latestReleaseURL, accept: "application/json")
        let tag = stringValue(release["tag_name"])
        let releaseURL = stringValue(release["html_url"])
        let releaseName = stringValue(release["name"]).isEmpty ? tag : stringValue(release["name"])
        let body = stringValue(release["body"])
        let prerelease = boolValue(release["prerelease"], fallback: false)
        let assets = parseAssets(release["assets"] as? [[String: Any]])
        let versionAsset = findVersionAsset(assets)
        let appAsset = findBestAppAsset(assets)

        var latestVersionCode = -1
        var latestVersionName = versionName(fromTag: tag)
        var sha256 = ""
        if let versionAsset, let versionURL = URL(string: versionAsset.downloadURL), !versionAsset.downloadURL.isEmpty {
            let version = try await jsonObject(from: versionURL, accept: "application/json")
            latestVersionCode = intValue(version["versionCode"], fallback: -1)
            latestVersionName = firstNonEmpty(stringValue(version["versionName"]), latestVersionName)
            sha256 = shaForAsset(in: version, assetName: appAsset?.name ?? "")
        }

        let currentCode = currentVersionCode()
        let currentName = currentVersionName()
        var newer = latestVersionCode > currentCode
        if latestVersionCode <= 0 {
            newer = compareVersions(latestVersionName, currentName) > 0
        }

        return AppUpdateInfo(
            updateAvailable: newer,
            currentVersionCode: currentCode,
            currentVersionName: currentName,
            latestVersionCode: latestVersionCode,
            latestVersionName: latestVersionName,
            tag: tag,
            releaseName: releaseName,
            releaseURL: releaseURL,
            releaseNotes: body,
            prerelease: prerelease,
            assetName: appAsset?.name ?? "",
            assetDownloadURL: appAsset?.downloadURL ?? "",
            assetSize: appAsset?.size ?? 0,
            assetSha256: sha256
        )
    }

    private func jsonObject(from url: URL, accept: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-iOS/\(currentVersionName())", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPStatusError(statusCode: 0, message: "Invalid HTTP response")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPStatusError(statusCode: http.statusCode, message: "HTTP \(http.statusCode)" + (body.isEmpty ? "" : ": \(IvLyricsUtilities.compactBody(body))"))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPStatusError(statusCode: http.statusCode, message: "Invalid JSON response")
        }
        return object
    }

    private func parseAssets(_ array: [[String: Any]]?) -> [Asset] {
        guard let array else { return [] }
        return array.map { object in
            Asset(
                name: stringValue(object["name"]),
                downloadURL: stringValue(object["browser_download_url"]),
                size: int64Value(object["size"], fallback: 0)
            )
        }
    }

    private func findVersionAsset(_ assets: [Asset]) -> Asset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix("-version.json") || name.hasSuffix("version.json")
        }
    }

    private func findBestAppAsset(_ assets: [Asset]) -> Asset? {
        let candidates = assets.filter { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".ipa") || name.hasSuffix(".xcarchive") || name.hasSuffix(".zip")
        }
        let signedCandidates = candidates.filter { !$0.name.lowercased().contains("unsigned") }
        return preferredAppAsset(in: signedCandidates) ?? preferredAppAsset(in: candidates)
    }

    private func preferredAppAsset(in candidates: [Asset]) -> Asset? {
        candidates.first { asset in
            let name = asset.name.lowercased()
            return name.contains("-release") && name.hasSuffix(".ipa")
        }
            ?? candidates.first { $0.name.lowercased().hasSuffix(".ipa") }
            ?? candidates.first { $0.name.lowercased().hasSuffix(".xcarchive") }
            ?? candidates.first { $0.name.lowercased().hasSuffix(".zip") }
            ?? candidates.first
    }

    private func shaForAsset(in version: [String: Any], assetName: String) -> String {
        for key in ["ipas", "archives", "assets", "apks"] {
            let sha = shaForAsset(version[key] as? [[String: Any]], assetName: assetName)
            if !sha.isEmpty {
                return sha
            }
        }
        return ""
    }

    private func shaForAsset(_ array: [[String: Any]]?, assetName: String) -> String {
        guard let array, !assetName.isEmpty else { return "" }
        for object in array where stringValue(object["name"]) == assetName {
            return stringValue(object["sha256"])
        }
        return ""
    }

    private func currentVersionCode() -> Int {
        intValue(Bundle.main.infoDictionary?["CFBundleVersion"], fallback: 0)
    }

    private func currentVersionName() -> String {
        stringValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"])
    }

    private func versionName(fromTag tag: String) -> String {
        let value = tag.trimmed
        return value.hasPrefix("v") || value.hasPrefix("V") ? String(value.dropFirst()) : value
    }

    private func compareVersions(_ left: String, _ right: String) -> Int {
        let leftParts = versionParts(left)
        let rightParts = versionParts(right)
        let count = max(leftParts.count, rightParts.count)
        for index in 0..<count {
            let a = index < leftParts.count ? leftParts[index] : "0"
            let b = index < rightParts.count ? rightParts[index] : "0"
            let result = compareVersionPart(a, b)
            if result != 0 {
                return result
            }
        }
        return 0
    }

    private func versionParts(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private func compareVersionPart(_ left: String, _ right: String) -> Int {
        if let a = Int64(left), let b = Int64(right) {
            return a == b ? 0 : (a < b ? -1 : 1)
        }
        let result = left.localizedCaseInsensitiveCompare(right)
        switch result {
        case .orderedAscending:
            return -1
        case .orderedDescending:
            return 1
        default:
            return 0
        }
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmed }
        if let value = value as? NSNumber { return value.stringValue.trimmed }
        return ""
    }

    private func boolValue(_ value: Any?, fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            let normalized = value.trimmed.lowercased()
            if ["true", "1", "yes"].contains(normalized) { return true }
            if ["false", "0", "no"].contains(normalized) { return false }
        }
        return fallback
    }

    private func intValue(_ value: Any?, fallback: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let int = Int(value.trimmed) { return int }
        return fallback
    }

    private func int64Value(_ value: Any?, fallback: Int64) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String, let int = Int64(value.trimmed) { return int }
        return fallback
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmed.isEmpty }?.trimmed ?? ""
    }

    private struct Asset {
        var name: String
        var downloadURL: String
        var size: Int64
    }
}
