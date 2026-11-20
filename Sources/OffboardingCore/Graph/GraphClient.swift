import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Network seam so GraphClient can be tested without real HTTP.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Refuses every redirect: Graph never redirects these calls, and following one could carry the bearer
/// token and a destructive request to a place nobody reviewed. A 3xx is therefore reported as an HTTP error.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    /// Default session is ephemeral (no on-disk response cache or cookies, so device data and tokens never
    /// land in ~/Library/Caches) and does not follow redirects.
    public init(session: URLSession = URLSessionTransport.lockedDownSession()) { self.session = session }

    public static func lockedDownSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GraphError.invalidResponse }
        return (data, http)
    }
}

/// All Microsoft Graph traffic goes through here.
///
/// - Tokens come from `AccessTokenProviding`; this type never handles credentials.
/// - GET is idempotent, so 429/5xx/transient network errors are retried with backoff.
/// - POST (and DELETE, Phase 9) are never retried: a timeout after sending is an unknown outcome,
///   not a failure. See `post`.
public struct GraphClient: Sendable {
    public static let v1Base = URL(string: "https://graph.microsoft.com/v1.0")!
    /// Only for read-only details that have no v1.0 equivalent (see `BetaMAMDeviceDetailsService`). Never used for writes.
    public static let betaBase = URL(string: "https://graph.microsoft.com/beta")!

    /// Longest Retry-After this client will wait for. A larger value is reported to the caller instead of
    /// freezing the screen for minutes.
    static let maxRetryWait: TimeInterval = 60

    /// Upper bound on pages per list (Graph pages hold up to 100-1000 items, so this is far above any real user).
    static let maxPages = 200

    private let tokenProvider: AccessTokenProviding
    private let scopes: [String]
    private let transport: HTTPTransport
    private let baseURL: URL
    private let maxAttempts: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let log = AppLogger(category: .graph)

    public init(
        tokenProvider: AccessTokenProviding,
        scopes: [String],
        transport: HTTPTransport = URLSessionTransport(),
        baseURL: URL = GraphClient.v1Base,
        maxAttempts: Int = 3,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            // Clamped: UInt64(...) traps on a negative, NaN, infinite or oversized value.
            let safe = seconds.isFinite ? min(max(seconds, 0), 60) : 0
            try await Task.sleep(nanoseconds: UInt64(safe * 1_000_000_000))
        }
    ) {
        self.tokenProvider = tokenProvider
        self.scopes = scopes
        self.transport = transport
        self.baseURL = baseURL
        self.maxAttempts = max(1, maxAttempts)
        self.sleep = sleep
    }

    // MARK: - Public API

    public func get<T: Decodable>(_ path: String, query: [(String, String)] = [], as type: T.Type = T.self) async throws -> T {
        let data = try await fetch(try makeURL(path: path, query: query))
        return try decode(T.self, from: data)
    }

    /// Follows `@odata.nextLink` until exhausted.
    public func getAll<T: Decodable>(_ path: String, query: [(String, String)] = [], as type: T.Type = T.self) async throws -> [T] {
        var results: [T] = []
        var next: URL? = try makeURL(path: path, query: query)
        var visited = Set<URL>()
        while let url = next {
            // Guards against a looping or endless nextLink: a repeated page, or more pages than any real list has.
            guard visited.insert(url).inserted, visited.count <= Self.maxPages else { throw GraphError.tooManyPages }
            let page: GraphPage<T> = try decode(GraphPage<T>.self, from: try await fetch(url))
            results.append(contentsOf: page.value)
            next = try page.nextLink.map(trustedPagingURL)
        }
        return results
    }

    /// Sends ONE POST. Never retried, never repeated: if the reply is lost the operation
    /// may already have happened, so the caller gets `GraphError.outcomeUnknown` and must verify.
    ///
    /// - Token problems throw before anything is sent (the operation definitely did not run).
    /// - 429 means Graph did not process the request: `.throttled`, still not retried here.
    /// - 5xx and any transport failure after sending are `.outcomeUnknown`.
    /// - Other 4xx are definite rejections.
    /// Returns the HTTP status (204 for Intune actions such as wipe).
    @discardableResult
    public func post<Body: Encodable>(_ path: String, body: Body) async throws -> Int {
        try await sendWrite(method: "POST", path: path, body: try JSONEncoder().encode(body))
    }

    /// Sends ONE POST with no body (Intune actions such as retire take none), with exactly the same guarantees as
    /// `post(_:body:)`. Returns the HTTP status (204 for retire).
    @discardableResult
    public func post(_ path: String) async throws -> Int {
        try await sendWrite(method: "POST", path: path, body: nil)
    }

    /// Sends ONE DELETE with no body, with exactly the same guarantees as `post` (never retried; a lost reply or
    /// 5xx is `.outcomeUnknown`). Returns the HTTP status (204 for Intune managed-device delete).
    @discardableResult
    public func delete(_ path: String) async throws -> Int {
        try await sendWrite(method: "DELETE", path: path, body: nil)
    }

    private func sendWrite(method: String, path: String, body: Data?) async throws -> Int {
        let token = try await tokenProvider.accessToken(for: scopes)
        let url = try makeURL(path: path, query: [])
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        log.info("\(method) \(url.path)") // path only: never the body or headers
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            // The request may have reached Graph, including when the task was cancelled in flight.
            throw GraphError.outcomeUnknown("no reply received: \(error.localizedDescription)")
        }
        switch response.statusCode {
        case 200..<300:
            return response.statusCode
        case 429:
            throw GraphError.throttled(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 500..<600:
            throw GraphError.outcomeUnknown("Graph answered HTTP \(response.statusCode)")
        default:
            throw Self.map(status: response.statusCode, data: data)
        }
    }

    // MARK: - URL building

    /// Percent-encodes query values strictly (RFC 3986 unreserved only). Notably '+' becomes %2B,
    /// otherwise some servers read it as a space and a UPN like "a+b@x.com" would not match.
    static func encode(_ value: String) -> String {
        // ASCII only: `.alphanumerics` also contains Unicode letters, which would stay unencoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func makeURL(path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(string: baseURL.absoluteString + path) else {
            throw GraphError.invalidResponse
        }
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        guard let url = components.url else { throw GraphError.invalidResponse }
        return url
    }

    /// The bearer token must only ever be sent to Graph, so a paging link pointing anywhere
    /// else is refused.
    private func trustedPagingURL(_ link: String) throws -> URL {
        guard let url = URL(string: link), url.scheme == "https", url.host == baseURL.host,
              url.port == nil, url.user == nil, url.password == nil else {
            throw GraphError.untrustedPagingLink(link)
        }
        return url
    }

    // MARK: - Request execution

    private func fetch(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let token = try await tokenProvider.accessToken(for: scopes)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            log.info("GET \(url.path)")
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as GraphError {
                throw error
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if attempt < maxAttempts {
                    log.warning("Network error on GET \(url.path), retrying (\(attempt)/\(maxAttempts))")
                    try await sleep(Self.backoff(attempt))
                    continue
                }
                throw GraphError.network(error.localizedDescription)
            }

            let status = response.statusCode
            switch status {
            case 200..<300:
                return data
            case 429:
                let retryAfter = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                guard attempt < maxAttempts, (retryAfter ?? 0) <= Self.maxRetryWait else { throw GraphError.throttled(retryAfter: retryAfter) }
                log.warning("Throttled (429) on GET \(url.path)")
                try await sleep(retryAfter ?? Self.backoff(attempt)) // honour Retry-After
            case 500..<600:
                guard attempt < maxAttempts else {
                    throw GraphError.server(status: status, detail: Self.detail(data))
                }
                log.warning("Graph \(status) on GET \(url.path), retrying (\(attempt)/\(maxAttempts))")
                try await sleep(Self.backoff(attempt))
            default:
                throw Self.map(status: status, data: data)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try GraphJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            throw GraphError.decoding(String(describing: error))
        }
    }

    static func backoff(_ attempt: Int) -> TimeInterval { min(pow(2, Double(attempt - 1)), 8) }

    /// Seconds from a Retry-After header, or nil when it is missing or not a sane non-negative number
    /// ("nan", "inf" and negative values parse as numbers but must never reach a sleep).
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    static func detail(_ data: Data) -> String? {
        (try? JSONDecoder().decode(GraphErrorBody.self, from: data))?.summary
    }

    static func map(status: Int, data: Data) -> GraphError {
        let summary = detail(data)
        switch status {
        case 401: return .unauthorized(detail: summary)
        case 403: return .forbidden(detail: summary)
        case 404: return .notFound(detail: summary)
        case 409: return .conflict(detail: summary)
        default: return .http(status: status, detail: summary)
        }
    }
}

struct GraphPage<T: Decodable>: Decodable {
    let value: [T]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}
