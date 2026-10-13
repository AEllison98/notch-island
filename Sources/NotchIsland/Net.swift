import Foundation

/// The app's only way onto the network. Every request goes through here, and anything not on
/// the list below is refused before it leaves the Mac, including a redirect to somewhere else.
///
///   lrclib.net                     synced lyrics: artist, title, album, duration
///   geocoding-api.open-meteo.com   a city name you typed, to find its coordinates
///   api.open-meteo.com             coordinates (rounded to about 10 km), for the weather
///
/// No cookies, no disk cache, no other headers beyond a plain User-Agent.
final class Net: @unchecked Sendable {
    static let shared = Net()

    static let allowedHosts: Set<String> = ["lrclib.net", "geocoding-api.open-meteo.com", "api.open-meteo.com"]

    enum Failure: Error, Equatable {
        case hostNotAllowed(String)
        case status(Int, retryAfter: TimeInterval?)
        case offline
    }

    /// Counted so the self-test can prove it made no requests.
    private(set) var requestCount = 0
    private let lock = NSLock()

    /// Created once, up front: a lazy session could be built twice by two first callers.
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "NotchIsland/0.1 (personal macOS app)"]
        session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    func get(_ url: URL) async throws -> Data {
        guard Self.isAllowed(url) else { throw Failure.hostNotAllowed(url.host ?? url.absoluteString) }
        lock.withLock { requestCount += 1 }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError where error.code != .cancelled {
            throw Failure.offline
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.offline }
        guard (200..<300).contains(http.statusCode) else {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Failure.status(http.statusCode, retryAfter: retry)
        }
        return data
    }

}

/// Refuses a redirect to anywhere not on the list.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Net.isAllowed(request.url) ? request : nil)
    }
}
