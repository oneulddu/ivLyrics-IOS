import Foundation

public enum ProviderParsingSupport {
    public static func extractJSONPObject(callbackText: String) throws -> Data {
        let text = callbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
              open < close,
              text[text.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ";"))).isEmpty else {
            throw LyricsProviderError.providerFormat
        }
        let callback = text[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        guard callback.range(of: #"^[A-Za-z_$][A-Za-z0-9_$.]*$"#, options: .regularExpression) != nil else {
            throw LyricsProviderError.providerFormat
        }
        let payload = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else { throw LyricsProviderError.providerFormat }
        return data
    }
}
