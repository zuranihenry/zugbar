import Foundation

/// The newest Zugbar release on GitHub.
public struct Release: Sendable, Equatable {
    /// e.g. "1.2.0", without the tag's leading "v".
    public let version: String
    public let url: URL

    static let latestURL = URL(string: "https://api.github.com/repos/zuranihenry/zugbar/releases/latest")!

    public static func latest(loader: @escaping DataLoader = URLSession.shared.loader) async throws -> Release {
        try parse(await loader(latestURL))
    }

    static func parse(_ data: Data) throws -> Release {
        struct DTO: Decodable {
            let tag_name: String
            let html_url: URL
        }
        let dto = try JSONDecoder().decode(DTO.self, from: data)
        let version = dto.tag_name.hasPrefix("v") ? String(dto.tag_name.dropFirst()) : dto.tag_name
        return Release(version: version, url: dto.html_url)
    }

    /// Compares dotted version numbers numerically, so "1.10.0" is newer than "1.9.2".
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (a, b) = (parts(candidate), parts(current))
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }
}
