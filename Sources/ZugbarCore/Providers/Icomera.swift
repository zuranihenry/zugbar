import Foundation

/// GPS from the Icomera router on trains whose Wi-Fi has no trip portal, e.g. DB Regio (www.ombord.info).
/// It only knows where the train is, so it refines a train followed online rather than being a provider of its own.
public struct Icomera: Sendable {
    static let positionURL = URL(string: "https://www.ombord.info/api/jsonp/position/")!

    public struct Fix: Sendable, Equatable {
        public var coordinate: Coordinate
        /// km/h
        public var speed: Int
        /// Course over ground, 0–360° clockwise from north; only meaningful while moving.
        public var heading: Double?
        /// Seconds since the router got the fix.
        public var age: TimeInterval
    }

    let loader: DataLoader

    public init(loader: @escaping DataLoader = URLSession.portal.loader) {
        self.loader = loader
    }

    public func fetch() async throws -> Fix {
        try Self.parse(await loader(Self.positionURL))
    }

    /// The API answers in JSONP, `({…});`, with every value as a string.
    public static func parse(_ data: Data) throws -> Fix {
        guard let text = String(data: data, encoding: .utf8),
              let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close
        else { throw ProviderError.missingResource("position") }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(text[open...close].utf8))
        // Every value is a string; "nan" or "inf" would trap when turned into an Int.
        func number(_ text: String?) -> Double? { text.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
        // GPS mode: 2 is a 2D fix, 3 a 3D fix; below that the coordinates are stale or made up.
        guard (number(raw.mode) ?? 3) >= 2,
              let latitude = number(raw.latitude), (-90...90).contains(latitude),
              let longitude = number(raw.longitude), (-180...180).contains(longitude),
              let coordinate = Coordinate(latitude, longitude)
        else { throw ProviderError.missingResource("GPS fix") }
        // m/s, capped well above any train.
        let metersPerSecond = min(max(number(raw.speed) ?? 0, 0), 150)
        return Fix(
            coordinate: coordinate,
            speed: Int((metersPerSecond * 3.6).rounded()),
            heading: number(raw.cmg),
            age: max(number(raw.age) ?? 0, 0)
        )
    }

    struct Raw: Decodable {
        let latitude: String?
        let longitude: String?
        /// m/s
        let speed: String?
        let cmg: String?
        let age: String?
        let mode: String?
    }
}
