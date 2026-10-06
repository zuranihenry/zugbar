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
    /// Short timeouts so probing a portal we aren't connected to fails fast.
    public static let portal: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
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
