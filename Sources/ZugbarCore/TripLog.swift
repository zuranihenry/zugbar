import Foundation

/// A finished trip on board a train, kept locally on this Mac.
public struct Trip: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var train: String
    public var from: String
    public var to: String
    public var start: Date
    public var end: Date
    /// Kilometers travelled, from the on-board GPS.
    public var distance: Double
    public var topSpeed: Int
    /// Delay at `to` in minutes, when the portal knew it.
    public var arrivalDelay: Int?

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Follows on-board data and turns it into trips. Only portal data counts: GPS proves the user is on that train,
/// which following a train online doesn't.
public struct TripRecorder: Sendable {
    struct Ongoing: Sendable {
        var train: String
        var from: String
        var start: Date
        var last: Date
        var position: Coordinate
        var distance = 0.0
        var topSpeed = 0
        var status: TrainStatus
    }

    private(set) var ongoing: Ongoing?

    /// Shorter or briefer than this is a train passed on a platform or a portal glimpsed in a station.
    static let minimumDistance = 5.0
    static let minimumDuration: TimeInterval = 5 * 60

    public init() {}

    /// Takes the next status; returns the previous trip when this one is from another train or followed online.
    public mutating func update(_ status: TrainStatus, at date: Date) -> Trip? {
        guard !status.isOnline, let train = status.trainName, let position = status.position else {
            return status.isOnline ? finish() : nil
        }
        var finished: Trip?
        if let current = ongoing, !TrainName.same(current.train, train) { finished = finish() }
        guard var current = ongoing else {
            // Boarded at the last stop left behind, or at the next one when the train hasn't left its first stop.
            let from = status.stops.last { $0.passed }?.name ?? status.nextStop?.name ?? "?"
            ongoing = Ongoing(train: train, from: from, start: date, last: date, position: position,
                              topSpeed: status.speed ?? 0, status: status)
            return finished
        }
        let step = current.position.distance(to: position)
        let hours = max(date.timeIntervalSince(current.last), 1) / 3600
        // Skip jumps no train could make, e.g. a bad fix after a tunnel.
        if step / hours < 350 { current.distance += step }
        current.position = position
        current.last = date
        current.topSpeed = max(current.topSpeed, status.speed ?? 0)
        current.status = status
        ongoing = current
        return finished
    }

    /// Ends the trip at the stop closest to where the train was last seen.
    public mutating func finish() -> Trip? {
        guard let current = ongoing else { return nil }
        ongoing = nil
        guard current.distance >= Self.minimumDistance, current.last.timeIntervalSince(current.start) >= Self.minimumDuration
        else { return nil }
        let stop = current.status.stops
            .filter { $0.coordinate != nil }
            .min { $0.coordinate!.distance(to: current.position) < $1.coordinate!.distance(to: current.position) }
        return Trip(train: current.train, from: current.from, to: stop?.name ?? "?", start: current.start, end: current.last,
                    distance: current.distance, topSpeed: current.topSpeed, arrivalDelay: stop?.delayMinutes)
    }
}

/// All recorded trips, newest first, with the totals the History tab shows.
public struct TripLog: Codable, Sendable, Equatable {
    public private(set) var trips: [Trip] = []

    public init() {}

    public mutating func add(_ trip: Trip) {
        trips.insert(trip, at: 0)
    }

    public mutating func remove(_ id: Trip.ID) {
        trips.removeAll { $0.id == id }
    }

    public func distance(inYearOf date: Date, calendar: Calendar = .current) -> Double {
        let year = calendar.component(.year, from: date)
        return trips.filter { calendar.component(.year, from: $0.start) == year }.map(\.distance).reduce(0, +)
    }

    public var fastest: Trip? { trips.max { $0.topSpeed < $1.topSpeed } }

    /// One row per trip; times in ISO 8601, distance in km.
    public func csv() -> String {
        func field(_ text: String) -> String {
            text.contains(where: { ",\"\n".contains($0) }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let header = "train,from,to,start,end,distance_km,duration_min,top_speed_kmh,arrival_delay_min"
        let rows = trips.map { trip in
            [field(trip.train), field(trip.from), field(trip.to),
             trip.start.formatted(.iso8601), trip.end.formatted(.iso8601),
             String(format: "%.1f", trip.distance), String(Int(trip.duration / 60)), String(trip.topSpeed),
             trip.arrivalDelay.map(String.init) ?? ""].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}
