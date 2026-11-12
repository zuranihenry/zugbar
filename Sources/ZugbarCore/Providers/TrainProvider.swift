import Foundation

public protocol TrainProvider: Sendable {
    var name: String { get }
    func fetch() async throws -> TrainStatus
}

public enum ProviderError: Error, Equatable {
    case badStatus(Int)
    case missingResource(String)
}

public typealias DataLoader = @Sendable (URL) async throws -> Data

public enum Providers {
    /// On-board Wi-Fi portals, probed in parallel.
    public static func onBoard(loader: @escaping DataLoader = URLSession.portal.loader) -> [any TrainProvider] {
        [ICEPortal(loader: loader), OEBBRailnet(loader: loader), SNCFInoui(loader: loader),
         Zugportal(loader: loader), CDWiFi(loader: loader)]
    }
}

/// What a portal last sent, so a timetable that changes once a minute isn't fetched again on every poll, and a
/// portal that said "not on a train" is left alone for a while.
final class PortalMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: (data: Data, at: Date)] = [:]
    private var pauses: [String: Date] = [:]
    private var marks: [String: Date] = [:]

    /// The answer from under `maxAge` seconds ago, or else a new one.
    func load(_ url: URL, maxAge: TimeInterval, now: Date, loader: DataLoader) async throws -> Data {
        if let kept = lock.withLock({ answers[url] }), now.timeIntervalSince(kept.at) < maxAge, now >= kept.at { return kept.data }
        let data = try await loader(url)
        lock.withLock { answers[url] = (data, now) }
        return data
    }

    func pause(_ key: String, until: Date) { lock.withLock { pauses[key] = until } }
    func isPaused(_ key: String, at now: Date) -> Bool { lock.withLock { pauses[key].map { now < $0 } ?? false } }
    func mark(_ key: String, at now: Date) { lock.withLock { marks[key] = now } }
    func marked(_ key: String) -> Date? { lock.withLock { marks[key] } }
    func forget() { lock.withLock { answers = [:]; pauses = [:]; marks = [:] } }
}

extension URLSession {
    /// Short timeouts so probing a portal we aren't connected to fails fast. Redirects to another host are a
    /// portal saying "not on this train", e.g. ÖBB's to a 150 KB web page; they fail instead of being followed.
    public static let portal: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    /// Transitous rejects requests without a User-Agent.
    public static let transitous: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "Zugbar/1.0 (+https://github.com/zuranihenry/zugbar)"]
        return URLSession(configuration: config)
    }()

    /// bahn.de's firewall holds most requests back for several seconds.
    public static let bahn: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = URLSession.transitous.configuration.httpAdditionalHeaders
        return URLSession(configuration: config)
    }()

    public var loader: DataLoader {
        { url in
            let (data, response) = try await self.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ProviderError.badStatus(http.statusCode)
            }
            return data
        }
    }
}

final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.host == task.originalRequest?.url?.host ? request : nil
    }
}

extension Error {
    /// No network, or a busy or broken server: says nothing about the train, so worth waiting out.
    public var isTransientNetwork: Bool {
        if self is URLError { return true }
        if case .badStatus(let code) = self as? ProviderError { return code == 429 || code >= 500 }
        return false
    }
}

extension URL {
    /// Like `append(queryItems:)`, but also encodes "+", which servers read as a space; IDs can contain it.
    mutating func appendQuery(_ items: [URLQueryItem]) {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return append(queryItems: items) }
        components.queryItems = (components.queryItems ?? []) + items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if let url = components.url { self = url }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension JSONDecoder {
    /// ISO 8601 dates with or without fractional seconds.
    static var portal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            guard let date = Date(portal: try container.decode(String.self)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date")
            }
            return date
        }
        return decoder
    }
}

extension Date {
    /// ISO 8601 with or without fractional seconds, in UTC or with an offset, "+01:00" or "+0100".
    init?(portal text: String) {
        // The strategy that keeps fractions of a second takes no offset: it would read local time as UTC.
        if text.hasSuffix("Z"),
           let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            self = date
        } else if let date = try? Date(text, strategy: .iso8601) {
            self = date
        } else {
            return nil
        }
    }
}
