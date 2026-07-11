import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class ProviderHTTPClient: @unchecked Sendable {
    public struct Response: Sendable {
        public let data: Data
        public let statusCode: Int
        public let headers: [String: String]
    }

    private let session: URLSession
    private let redirectDelegate: ProviderRedirectDelegate
    public let defaultTimeout: TimeInterval
    public let maxResponseBytes: Int

    public init(configuration: URLSessionConfiguration = .ephemeral,
                defaultTimeout: TimeInterval = 12,
                maxResponseBytes: Int = 2_000_000) {
        let redirectDelegate = ProviderRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate,
                                  delegateQueue: nil)
        self.defaultTimeout = defaultTimeout
        self.maxResponseBytes = max(1, maxResponseBytes)
    }

    public func get(_ url: URL, queryItems: [URLQueryItem] = [],
                    headers: [String: String] = [:], timeout: TimeInterval? = nil,
                    allowedStatus: Range<Int> = 200..<300) async throws -> Response {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LyricsProviderError.providerFormat
        }
        if !queryItems.isEmpty { components.queryItems = (components.queryItems ?? []) + queryItems }
        guard let finalURL = components.url else { throw LyricsProviderError.providerFormat }
        return try await send(method: "GET", url: finalURL, body: nil, headers: headers,
                              timeout: timeout, allowedStatus: allowedStatus)
    }

    public func post(_ url: URL, body: Data? = nil, headers: [String: String] = [:],
                     timeout: TimeInterval? = nil,
                     allowedStatus: Range<Int> = 200..<300) async throws -> Response {
        try await send(method: "POST", url: url, body: body, headers: headers,
                       timeout: timeout, allowedStatus: allowedStatus)
    }

    public func send(method: String, url: URL, body: Data?, headers: [String: String],
                     timeout: TimeInterval? = nil,
                     allowedStatus: Range<Int> = 200..<300) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout ?? defaultTimeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw LyricsProviderError.transient }
            if let length = http.value(forHTTPHeaderField: "Content-Length"),
               let count = Int(length), count > maxResponseBytes { throw LyricsProviderError.providerFormat }
            guard data.count <= maxResponseBytes else { throw LyricsProviderError.providerFormat }
            guard allowedStatus.contains(http.statusCode) else { throw mapStatus(http) }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
            return Response(data: data, statusCode: http.statusCode, headers: headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LyricsProviderError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled {
                if Task.isCancelled { throw CancellationError() }
                throw LyricsProviderError.cancelled
            }
            switch error.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                throw LyricsProviderError.transient
            default:
                throw LyricsProviderError.transient
            }
        } catch {
            throw LyricsProviderError.transient
        }
    }

    public func decodeJSON<T: Decodable>(_ type: T.Type, from response: Response,
                                         decoder: JSONDecoder = JSONDecoder()) throws -> T {
        do { return try decoder.decode(type, from: response.data) }
        catch { throw LyricsProviderError.providerFormat }
    }

    public func decodeHTML(from response: Response) throws -> String {
        guard let value = String(data: response.data, encoding: .utf8) else {
            throw LyricsProviderError.providerFormat
        }
        return value
    }

    private func mapStatus(_ response: HTTPURLResponse) -> LyricsProviderError {
        switch response.statusCode {
        case 401: return .authenticationRequired
        case 403: return .authenticationFailed
        case 404: return .miss
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        case 500...599: return .transient
        default: return .providerFormat
        }
    }
}

/// Provider requests may contain bearer tokens or cookies. Do not follow redirects,
/// because forwarding those credentials to a different host is never acceptable.
final class ProviderRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
