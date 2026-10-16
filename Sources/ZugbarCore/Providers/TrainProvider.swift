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
        [ICEPortal(loader: loader), OEBBRailnet(loader: loader), SNCFInoui(loader: loader)]
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
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            return try Date(text, strategy: .iso8601)
        }
        return decoder
    }
}
