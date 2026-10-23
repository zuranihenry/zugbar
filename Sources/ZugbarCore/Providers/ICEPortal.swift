import Foundation

/// Deutsche Bahn on-board portal (WIFIonICE / WIFI@DB).
public struct ICEPortal: TrainProvider {
    public let name = "Deutsche Bahn"

    static let statusURL = URL(string: "https://iceportal.de/api1/rs/status")!
    static let tripURL = URL(string: "https://iceportal.de/api1/rs/tripInfo/trip")!

    let loader: DataLoader

    public init(loader: @escaping DataLoader = URLSession.portal.loader) {
        self.loader = loader
    }

    public func fetch() async throws -> TrainStatus {
        async let status = loader(Self.statusURL)
        async let trip = loader(Self.tripURL)
        return try Self.parse(status: await status, trip: await trip)
    }

    public static func parse(status statusData: Data, trip tripData: Data, now: Date = Date()) throws -> TrainStatus {
        let decoder = JSONDecoder()
        let status = try decoder.decode(StatusDTO.self, from: statusData)
        let trip = try decoder.decode(TripDTO.self, from: tripData).trip

        let stops = trip.stops.map { stop in
            Stop(
                id: stop.station.evaNr ?? stop.station.name,
                name: stop.station.name,
                scheduledArrival: date(stop.timetable?.scheduledArrivalTime),
                expectedArrival: date(stop.timetable?.actualArrivalTime),
                scheduledDeparture: date(stop.timetable?.scheduledDepartureTime),
                expectedDeparture: date(stop.timetable?.actualDepartureTime),
                track: stop.track?.actual ?? stop.track?.scheduled,
                passed: stop.info?.passed ?? false,
                delayReasons: (stop.delayReasons ?? []).compactMap(\.text),
                coordinate: Coordinate(stop.station.geocoordinates?.latitude, stop.station.geocoordinates?.longitude),
                // Status 1 at distance 0: dropped from the run, as KDE Itinerary reads it.
                cancelled: stop.info?.status == 1 && (stop.info?.distanceFromStart ?? 0) == 0
            )
        }

        // actualPosition only moves on at each stop, so between stops count on from the stop last left.
        var progress: Double?
        if let total = trip.totalDistance, total > 0 {
            var along = trip.actualPosition
            let evaNr = { (id: String) in id.split(separator: "_").first.map(String.init) ?? id }
            if let moved = trip.distanceFromLastStop, let last = trip.stopInfo?.actualLast.map(evaNr),
               let index = trip.stops.firstIndex(where: { $0.station.evaNr.map(evaNr) == last }),
               let start = trip.stops[index].info?.distanceFromStart {
                // Never past the next stop (cancelled ones sit at 0), however far the count runs on.
                let next = trip.stops[(index + 1)...].lazy.compactMap { $0.info?.distanceFromStart }.first { $0 > start }
                along = max(along ?? 0, min(start + moved, next ?? total))
            }
            if let along { progress = min(max(along / total, 0), 1) }
        }

        // In tunnels the position is stale but the speed stays live, as the portal's own page shows it. -1 means none.
        let hasSpeed = status.gpsStatus == "VALID" || status.gpsStatus == "LAST_KNOWN_POSITION"

        return TrainStatus(
            provider: "Deutsche Bahn",
            trainName: [trip.trainType, trip.vzn].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
            destination: trip.stopInfo?.finalStationName ?? stops.last?.name,
            speed: hasSpeed ? status.speed.flatMap { $0 >= 0 ? Int($0.rounded()) : nil } : nil,
            stops: stops,
            nextStopID: trip.stopInfo?.actualNext,
            progress: progress,
            vehicle: ICEVehicle.describe(tzn: status.tzn),
            wagonClass: status.wagonClass.flatMap { ["FIRST": 1, "SECOND": 2][$0] },
            // Most trains dropped the connectivity block with its forecast and only send the current level.
            internet: status.connectivity.flatMap { internet($0, now: now) }
                ?? quality(status.internet).map { Internet(current: $0) },
            portal: .portal("ICE Portal", "https://iceportal.de"),
            position: status.gpsStatus == "VALID" ? Coordinate(status.latitude, status.longitude) : nil
        )
    }

    private static func internet(_ connectivity: StatusDTO.Connectivity, now: Date) -> Internet? {
        guard let current = quality(connectivity.currentState) else { return nil }
        return Internet(
            current: current,
            next: quality(connectivity.nextState),
            nextChange: connectivity.remainingTimeSeconds.map { now.addingTimeInterval(TimeInterval($0)) }
        )
    }

    private static func quality(_ state: String?) -> Internet.Quality? {
        switch state {
        case "HIGH": .good
        case "WEAK", "MIDDLE", "UNSTABLE": .weak
        case "NO_INTERNET", "OFFLINE": Internet.Quality.none
        default: nil
        }
    }

    private static func date(_ millis: Int64?) -> Date? {
        millis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    struct StatusDTO: Decodable {
        let speed: Double?
        let gpsStatus: String?
        let latitude: Double?
        let longitude: Double?
        let tzn: String?
        let wagonClass: String?
        let internet: String?
        let connectivity: Connectivity?

        struct Connectivity: Decodable {
            let currentState: String?
            let nextState: String?
            let remainingTimeSeconds: Int?

            enum CodingKeys: String, CodingKey { case currentState, nextState, remainingTimeSeconds }

            // remainingTimeSeconds shows up both as a number and as a string.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                currentState = try container.decodeIfPresent(String.self, forKey: .currentState)
                nextState = try container.decodeIfPresent(String.self, forKey: .nextState)
                remainingTimeSeconds = (try? container.decodeIfPresent(Int.self, forKey: .remainingTimeSeconds))
                    ?? (try? container.decodeIfPresent(String.self, forKey: .remainingTimeSeconds)).flatMap { $0.flatMap(Int.init) }
            }
        }
    }

    struct TripDTO: Decodable {
        let trip: Trip

        struct Trip: Decodable {
            let trainType: String?
            let vzn: String?
            let actualPosition: Double?
            let distanceFromLastStop: Double?
            let totalDistance: Double?
            let stopInfo: StopInfo?
            let stops: [Stop]
        }

        struct StopInfo: Decodable {
            let actualNext: String?
            let actualLast: String?
            let finalStationName: String?
        }

        struct Stop: Decodable {
            let station: Station
            let timetable: Timetable?
            let track: Track?
            let info: Info?
            let delayReasons: [DelayReason]?
        }

        struct DelayReason: Decodable {
            let text: String?
        }

        struct Station: Decodable {
            let evaNr: String?
            let name: String
            let geocoordinates: Geo?
        }

        struct Geo: Decodable {
            let latitude: Double?
            let longitude: Double?
        }

        struct Timetable: Decodable {
            let scheduledArrivalTime: Int64?
            let actualArrivalTime: Int64?
            let scheduledDepartureTime: Int64?
            let actualDepartureTime: Int64?
        }

        struct Track: Decodable {
            let scheduled: String?
            let actual: String?
        }

        struct Info: Decodable {
            let passed: Bool?
            let status: Int?
            let distanceFromStart: Double?
        }
    }
}
