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

/// A train running close to a GPS fix.
public struct NearbyTrain: Sendable, Equatable {
    public let tripID: String
    public let name: String
    /// Seconds between now and when the live times have the train at the fix.
    public let lag: TimeInterval
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

    /// The train a router's GPS fix belongs to: on a line through the fix, going the same way, closest in time.
    /// The live times can lag the real train by minutes, so the time only ranks trains that fit the line.
    /// `excluding` holds trips already found not to be it on this ride.
    public func train(at fix: Icomera.Fix, heading: Double, excluding: Set<String> = [], now: Date = Date()) async throws -> NearbyTrain? {
        let (latitude, longitude) = (fix.coordinate.latitude, fix.coordinate.longitude)
        var url = Transitous.base.appending(path: "v6/map/trips")
        // Trips crossing a ~1.7 km box; in a city a larger one means megabytes of buses.
        url.append(queryItems: [
            URLQueryItem(name: "zoom", value: "14"),
            URLQueryItem(name: "min", value: "\(latitude - 0.015),\(longitude - 0.025)"),
            URLQueryItem(name: "max", value: "\(latitude + 0.015),\(longitude + 0.025)"),
            URLQueryItem(name: "startTime", value: now.addingTimeInterval(-20 * 60).formatted(.iso8601)),
            URLQueryItem(name: "endTime", value: now.addingTimeInterval(5 * 60).formatted(.iso8601)),
            URLQueryItem(name: "precision", value: "5"),
        ])
        let segments = try JSONDecoder.portal.decode([Segment].self, from: await loader(url))
            .filter { segment in !segment.trips.contains { excluding.contains($0.tripId) } }
        return Self.train(at: fix.coordinate, heading: heading, in: segments, now: now)
    }

    /// Regional trains first: long-distance trains share their lines, and in Germany they have a portal of their own.
    static func train(at coordinate: Coordinate, heading: Double, in segments: [Segment], now: Date) -> NearbyTrain? {
        let regional: Set = ["REGIONAL_FAST_RAIL", "REGIONAL_RAIL", "SUBURBAN", "RAIL"]
        let longDistance: Set = ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"]
        return closest(to: coordinate, heading: heading, in: segments.filter { regional.contains($0.mode) }, now: now)
            ?? closest(to: coordinate, heading: heading, in: segments.filter { longDistance.contains($0.mode) }, now: now)
    }

    private static func closest(to coordinate: Coordinate, heading: Double, in segments: [Segment], now: Date) -> NearbyTrain? {
        let matches = segments.compactMap { segment -> (train: NearbyTrain, offset: Double)? in
            guard let trip = segment.trips.first, let name = trip.displayName,
                  let departure = segment.departure, let arrival = segment.arrival, arrival > departure
            else { return nil }
            let from = Coordinate(latitude: segment.from.lat, longitude: segment.from.lon)
            let to = Coordinate(latitude: segment.to.lat, longitude: segment.to.lon)
            // The track between the two stops, or a straight line where the feed has no shape.
            let shape = segment.polyline.map { Route.decode($0, precision: 5) } ?? []
            let shaped = shape.count >= 3
            let route = Route(points: shaped ? shape : [from, to])
            guard route.length > 0 else { return nil }
            let position = route.projection(of: coordinate)
            // Projections stop at the ends, so a fix past the last stop or on a branch is off the line.
            guard position.offset < (shaped ? 0.5 : 1.5),
                  let bearing = route.bearing(at: position.along),
                  abs((bearing - heading + 540).truncatingRemainder(dividingBy: 360) - 180) < 60
            else { return nil }
            let expected = departure.addingTimeInterval(arrival.timeIntervalSince(departure) * position.along / route.length)
            let lag = abs(now.timeIntervalSince(expected))
            guard lag < 20 * 60 else { return nil }
            return (NearbyTrain(tripID: trip.tripId, name: name, lag: lag), position.offset)
        }
        // Within a minute of each other, the one closer to the line.
        return matches.min { a, b in
            abs(a.train.lag - b.train.lag) < 60 ? a.offset < b.offset : a.train.lag < b.train.lag
        }?.train
    }

    struct Segment: Decodable {
        let mode: String
        /// Encoded with the requested precision; only asked for when matching GPS.
        var polyline: String?
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
