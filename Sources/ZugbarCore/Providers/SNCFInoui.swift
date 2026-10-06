import Foundation

/// SNCF on-board portal on TGV INOUI (wifi.sncf). Endpoints per felix-zenk/onboardapis.
public struct SNCFInoui: TrainProvider {
    public let name = "SNCF"

    static let detailsURL = URL(string: "https://wifi.sncf/router/api/train/details")!
    static let gpsURL = URL(string: "https://wifi.sncf/router/api/train/gps")!

    let loader: DataLoader

    public init(loader: @escaping DataLoader = URLSession.portal.loader) {
        self.loader = loader
    }

    public func fetch() async throws -> TrainStatus {
        async let details = loader(Self.detailsURL)
        async let gps = loader(Self.gpsURL)
        return try Self.parse(details: await details, gps: try? await gps)
    }

    public static func parse(details detailsData: Data, gps gpsData: Data?) throws -> TrainStatus {
        let decoder = JSONDecoder.portal
        let details = try decoder.decode(Details.self, from: detailsData)
        let gps = gpsData.flatMap { try? decoder.decode(GPS.self, from: $0) }

        let stops = details.stops.filter { !($0.isRemoved ?? false) }.map { stop in
            // The portal only has arrival times plus the dwell time in minutes.
            let dwell = TimeInterval((stop.duration ?? 0) * 60)
            return Stop(
                id: stop.code,
                name: stop.label,
                scheduledArrival: stop.theoricDate,
                expectedArrival: stop.realDate,
                scheduledDeparture: stop.theoricDate?.addingTimeInterval(dwell),
                expectedDeparture: stop.realDate?.addingTimeInterval(dwell),
                track: stop.platform?.nilIfEmpty,
                passed: (stop.progress?.progressPercentage ?? 0) >= 100,
                coordinate: Coordinate(stop.coordinates?.latitude, stop.coordinates?.longitude)
            )
        }

        let traveled = details.stops.compactMap(\.progress?.traveledDistance).reduce(0, +)
        let remaining = details.stops.compactMap(\.progress?.remainingDistance).reduce(0, +)

        return TrainStatus(
            provider: "SNCF",
            trainName: ["TGV INOUI", details.number].compactMap { $0 }.joined(separator: " "),
            destination: stops.last?.name,
            speed: gps.flatMap(\.speed).map { Int(($0 * 3.6).rounded()) },
            stops: stops,
            nextStopID: stops.first { !$0.passed }?.id,
            progress: traveled + remaining > 0 ? traveled / (traveled + remaining) : nil,
            portal: .portal("SNCF Wi-Fi", "https://wifi.sncf"),
            position: Coordinate(gps?.latitude, gps?.longitude)
        )
    }

    struct Details: Decodable {
        let number: String?
        let stops: [Stop]

        struct Stop: Decodable {
            let code: String
            let label: String
            let theoricDate: Date?
            let realDate: Date?
            let duration: Int?
            let platform: String?
            let isRemoved: Bool?
            let progress: Progress?
            let coordinates: Geo?
        }

        struct Geo: Decodable {
            let latitude: Double?
            let longitude: Double?
        }

        struct Progress: Decodable {
            let progressPercentage: Double?
            let traveledDistance: Double?
            let remainingDistance: Double?
        }
    }

    struct GPS: Decodable {
        /// m/s
        let speed: Double?
        let latitude: Double?
        let longitude: Double?
    }
}
