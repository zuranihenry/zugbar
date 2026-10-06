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

    /// Connecting trains at a stop, as listed by the portal (works without internet access).
    public func connections(at stop: Stop) async throws -> [Connection] {
        let evaNr = stop.id.split(separator: "_").first.map(String.init) ?? stop.id
        let url = URL(string: "https://iceportal.de/api1/rs/tripInfo/connection/\(stop.id)")!
        return try Self.parseConnections(await loader(url), station: stop.name, stationID: stop.id, evaNr: evaNr)
    }

    static func parseConnections(_ data: Data, station: String, stationID: String, evaNr: String) throws -> [Connection] {
        struct Response: Decodable { let connections: [Item]? }
        struct Item: Decodable {
            let trainType: String?
            let vzn: String?
            let station: TripDTO.Station?
            let timetable: TripDTO.Timetable?
            let track: TripDTO.Track?
        }
        return try JSONDecoder().decode(Response.self, from: data).connections?.compactMap { item in
            let name = [item.trainType, item.vzn].compactMap { $0 }.joined(separator: " ")
            guard !name.isEmpty else { return nil }
            return Connection(
                tripID: "iceportal:\(evaNr):\(name)",
                name: name,
                headsign: item.station?.name,
                station: station,
                scheduledDeparture: date(item.timetable?.scheduledDepartureTime),
                expectedDeparture: date(item.timetable?.actualDepartureTime),
                track: item.track?.actual ?? item.track?.scheduled,
                finalStop: item.station?.name,
                portalStationID: stationID
            )
        } ?? []
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
                coordinate: Coordinate(stop.station.geocoordinates?.latitude, stop.station.geocoordinates?.longitude)
            )
        }

        var progress: Double?
        if let position = trip.actualPosition, let total = trip.totalDistance, total > 0 {
            progress = min(max(position / total, 0), 1)
        }

        return TrainStatus(
            provider: "Deutsche Bahn",
            trainName: [trip.trainType, trip.vzn].compactMap { $0 }.joined(separator: " ").nilIfEmpty,
            destination: trip.stopInfo?.finalStationName ?? stops.last?.name,
            speed: status.gpsStatus == "VALID" ? status.speed.map { Int($0.rounded()) } : nil,
            stops: stops,
            nextStopID: trip.stopInfo?.actualNext,
            progress: progress,
            vehicle: ICEVehicle.describe(tzn: status.tzn),
            wagonClass: status.wagonClass.flatMap { ["FIRST": 1, "SECOND": 2][$0] },
            internet: status.connectivity.flatMap { internet($0, now: now) },
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
        case "NO_INTERNET": Internet.Quality.none
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
            let totalDistance: Double?
            let stopInfo: StopInfo?
            let stops: [Stop]
        }

        struct StopInfo: Decodable {
            let actualNext: String?
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
        }
    }
}
