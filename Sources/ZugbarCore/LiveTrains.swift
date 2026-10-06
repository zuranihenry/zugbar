import Foundation

/// A long-distance train running right now, between two stops.
public struct LiveTrain: Sendable, Equatable, Identifiable {
    public var id: String { tripID }
    public let tripID: String
    public let name: String
    public let from: String
    public let to: String
    /// Average km/h between the two stops; an estimate, not live speed.
    public let averageSpeed: Int
    public let delayMinutes: Int

    public static func fastest(_ trains: [LiveTrain], count: Int = 2) -> [LiveTrain] {
        Array(trains.sorted { $0.averageSpeed > $1.averageSpeed }.prefix(count))
    }

    public static func mostDelayed(_ trains: [LiveTrain], count: Int = 2) -> [LiveTrain] {
        Array(trains.filter { $0.delayMinutes > 0 }.sorted { $0.delayMinutes > $1.delayMinutes }.prefix(count))
    }
}

extension TransitousClient {
    public func liveTrains(at now: Date = Date()) async throws -> [LiveTrain] {
        var url = Transitous.base.appending(path: "v6/map/trips")
        url.append(queryItems: [
            URLQueryItem(name: "zoom", value: "6"),
            URLQueryItem(name: "min", value: "41,-5"),
            URLQueryItem(name: "max", value: "56,20"),
            URLQueryItem(name: "startTime", value: now.formatted(.iso8601)),
            URLQueryItem(name: "endTime", value: now.addingTimeInterval(60).formatted(.iso8601)),
            URLQueryItem(name: "precision", value: "0"),
        ])
        return try Self.parseLiveTrains(await loader(url))
    }

    static func parseLiveTrains(_ data: Data) throws -> [LiveTrain] {
        let segments = try JSONDecoder.portal.decode([Segment].self, from: data)
        var seen = Set<String>()
        return segments.compactMap { segment in
            guard ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"].contains(segment.mode),
                  let trip = segment.trips.first, let name = trip.displayName, seen.insert(trip.tripId).inserted,
                  let departure = segment.departure, let arrival = segment.arrival
            else { return nil }

            // The API's `distance` covers the whole trip, so estimate the hop from coordinates
            // plus 10% for curves. Short hops are too noisy to be meaningful.
            let duration = arrival.timeIntervalSince(departure)
            let kilometers = segment.from.distance(to: segment.to) * 1.1
            guard duration >= 8 * 60, kilometers >= 30 else { return nil }
            let speed = Int((kilometers / (duration / 3600)).rounded())
            guard speed <= 350 else { return nil }

            return LiveTrain(
                tripID: trip.tripId,
                name: name,
                from: StationName.tidy(segment.from.name),
                to: StationName.tidy(segment.to.name),
                averageSpeed: speed,
                delayMinutes: segment.scheduledArrival.map { minutes(from: $0, to: arrival) } ?? 0
            )
        }
    }

    struct Segment: Decodable {
        let mode: String
        let trips: [Transitous.TripRef]
        let from: Point
        let to: Point
        let departure: Date?
        let arrival: Date?
        let scheduledArrival: Date?
    }

    struct Point: Decodable {
        let name: String
        let lat: Double
        let lon: Double

        func distance(to other: Point) -> Double {
            Coordinate(latitude: lat, longitude: lon).distance(to: Coordinate(latitude: other.lat, longitude: other.lon))
        }
    }
}
