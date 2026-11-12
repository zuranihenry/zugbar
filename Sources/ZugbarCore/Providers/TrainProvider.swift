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
        onBoard(loader: loader, json: loader)
    }

    /// `json`: for the portals that are only looked for now and then; see `URLSession.jsonLoader`.
    public static func onBoard(loader: @escaping DataLoader, json: @escaping DataLoader) -> [any TrainProvider] {
        [ICEPortal(loader: loader), OEBBRailnet(loader: loader), SNCFInoui(loader: loader),
         Zugportal(loader: json, router: loader), CDWiFi(loader: json)]
    }

    /// A new network may be a train: the portals left alone after not answering are asked again right away.
    public static func joinedNetwork() {
        Zugportal.shared.forget()
        CDWiFi.shared.forget()
    }
}

/// What a portal last sent, so a timetable that changes once a minute isn't fetched again on every poll, and a
/// portal that didn't answer with a train is left alone for a while. Shared by every probe of that portal.
final class PortalMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [URL: (data: Data, at: Date)] = [:]
    private var pauses: [String: Date] = [:]
    private var notes: [String: String] = [:]
    private var failures = 0
    private var lastSuccess: Date?

    /// The answer from under `maxAge` seconds ago, or else a new one.
    func load(_ url: URL, maxAge: TimeInterval, now: Date, loader: DataLoader) async throws -> Data {
        if let kept = lock.withLock({ answers[url] }), now.timeIntervalSince(kept.at) < maxAge, now >= kept.at { return kept.data }
        let data = try await loader(url)
        lock.withLock { answers[url] = (data, now) }
        return data
    }

    /// Whether the portal is to be left alone: it didn't answer with a train when last asked.
    func isPaused(at now: Date) -> Bool { isPaused("portal", at: now) }

    /// No train in the answer, whatever came instead: an error, a timeout, nothing, a web page. The portal is left
    /// alone for a minute, then two, four, up to half an hour. Not after a gap in a trip that answered within the
    /// last two minutes: that's the Wi-Fi, and asking again is how the trip comes back.
    func failed(at now: Date) {
        lock.withLock {
            answers = [:]
            if let lastSuccess, now.timeIntervalSince(lastSuccess) < 120, now >= lastSuccess { return }
            pauses["portal"] = now.addingTimeInterval(min(60 * pow(2, Double(min(failures, 5))), 30 * 60))
            failures += 1
        }
    }

    func succeeded(at now: Date) {
        lock.withLock {
            failures = 0
            lastSuccess = now
            pauses["portal"] = nil
        }
    }

    func pause(_ key: String, until: Date) { lock.withLock { pauses[key] = until } }
    func isPaused(_ key: String, at now: Date) -> Bool { lock.withLock { pauses[key].map { now < $0 } ?? false } }

    subscript(note: String) -> String? {
        get { lock.withLock { notes[note] } }
        set { lock.withLock { notes[note] = newValue } }
    }

    func forget() {
        lock.withLock {
            answers = [:]
            pauses = [:]
            notes = [:]
            failures = 0
            lastSuccess = nil
        }
    }
}

/// A field that's missing its value instead of failing the whole answer when the portal sends another type than
/// expected: the rest still shows.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Text the portal may also send as a number, e.g. a station ID or a track.
struct LenientString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text.nilIfEmpty
        } else if let number = try? container.decode(Int.self) {
            value = String(number)
        } else {
            value = nil
        }
    }
}

/// true, "true" or 1.
struct LenientBool: Decodable {
    let value: Bool?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            value = flag
        } else if let text = try? container.decode(String.self) {
            value = ["true": true, "false": false][text.lowercased()]
        } else if let number = try? container.decode(Int.self) {
            value = number != 0
        } else {
            value = nil
        }
    }
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

    /// Like `loader`, for portals whose host may answer off the train too, with a web page or a captive portal's:
    /// gives up on an answer that doesn't start like JSON, or is over a megabyte, without downloading the rest.
    public var jsonLoader: DataLoader {
        { url in
            let limit = 1_000_000
            let (bytes, response) = try await self.bytes(from: url)
            do {
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw ProviderError.badStatus(http.statusCode)
                }
                guard response.expectedContentLength <= Int64(limit) else { throw ProviderError.missingResource("JSON") }
                var data = Data()
                for try await byte in bytes {
                    if data.isEmpty {
                        if [0x20, 0x09, 0x0A, 0x0D].contains(byte) { continue }
                        guard byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") else { throw ProviderError.missingResource("JSON") }
                    }
                    data.append(byte)
                    guard data.count <= limit else { throw ProviderError.missingResource("JSON") }
                }
                return data
            } catch {
                bytes.task.cancel()
                throw error
            }
        }
    }

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
