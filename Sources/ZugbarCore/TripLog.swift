import Foundation

/// A finished trip on board a train, kept locally on this Mac.
public struct Trip: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var train: String
    public var from: String
    public var to: String
    public var start: Date
    public var end: Date
    /// Kilometers travelled, from the on-board speed, or GPS where there is none.
    public var distance: Double
    public var topSpeed: Int
    /// Delay at `to` in minutes, when the portal knew it.
    public var arrivalDelay: Int?
    /// Speed and delay along the way, for the charts; `nil` for trips recorded before there were any.
    public var samples: [RideSample]?

    public init(id: UUID = UUID(), train: String, from: String, to: String, start: Date, end: Date, distance: Double,
                topSpeed: Int, arrivalDelay: Int? = nil, samples: [RideSample]? = nil) {
        self.id = id
        self.train = train
        self.from = from
        self.to = to
        self.start = start
        self.end = end
        self.distance = distance
        self.topSpeed = topSpeed
        self.arrivalDelay = arrivalDelay
        self.samples = samples
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Follows on-board data and turns it into trips. Only portal data counts: GPS proves the user is on that train,
/// which following a train online doesn't.
public struct TripRecorder: Sendable {
    struct Ongoing: Sendable {
        var id = UUID()
        var train: String
        var from: String
        var start: Date
        var last: Date
        var position: Coordinate
        var distance = 0.0
        var topSpeed = 0
        var status: TrainStatus
        var sampler = RideSampler()

        /// The trip as it would be logged now, ending at the stop closest to where the train was last seen.
        var trip: Trip {
            let stop = status.stops
                .filter { $0.coordinate != nil }
                .min { $0.coordinate!.distance(to: position) < $1.coordinate!.distance(to: position) }
            return Trip(id: id, train: train, from: from, to: stop?.name ?? "?", start: start, end: last, distance: distance,
                        topSpeed: topSpeed, arrivalDelay: stop?.delayMinutes, samples: sampler.all)
        }
    }

    private(set) var ongoing: Ongoing?
    /// A trip ended for going quiet, kept a while in case the same ride comes back: the lid was closed or the
    /// portal was down, rather than the user getting off.
    private var paused: Ongoing?

    /// Shorter or briefer than this is a train passed on a platform or a portal glimpsed in a station.
    static let minimumDistance = 5.0
    static let minimumDuration: TimeInterval = 5 * 60
    /// How long after going quiet a ride can still go on.
    static let resumeWithin: TimeInterval = 3 * 3600

    public init() {}

    /// Takes the next status; returns the previous trip when this one is from another train or followed online.
    public mutating func update(_ status: TrainStatus, at date: Date) -> Trip? {
        var finished = finishIfIdle(at: date)
        guard !status.isOnline, let train = status.trainName, let position = status.position else {
            // The same train followed online while its portal is down: the ride goes on.
            if status.isOnline, let riding = ongoing ?? paused, let name = status.trainName, TrainName.same(riding.train, name) {
                return finished
            }
            return status.isOnline ? finish() ?? finished : finished
        }
        if let current = ongoing, !TrainName.same(current.train, train) { finished = finish() ?? finished }
        if ongoing == nil, let paused, Self.sameRun(paused, status, at: date) {
            // Back on the same ride: it goes on as the same trip, and the part logged meanwhile is updated.
            ongoing = paused
            if finished?.id == paused.id { finished = nil }
        }
        paused = nil
        guard var current = ongoing else {
            // Boarded at the last stop left behind, or at the next one when the train hasn't left its first stop.
            let from = status.stops.last { $0.passed }?.name ?? status.nextStop?.name ?? "?"
            var started = Ongoing(train: train, from: from, start: date, last: date, position: position,
                                  topSpeed: status.speed ?? 0, status: status)
            started.sampler.record(status, distance: 0, at: 0)
            ongoing = started
            return finished
        }
        let seconds = date.timeIntervalSince(current.last)
        if let speed = status.speed, let previous = current.status.speed, (0...60).contains(seconds) {
            // Portal fixes lag and change only every ~10 s, far less often than we poll; their speed doesn't.
            current.distance += Double(previous + speed) / 2 * seconds / 3600
        } else {
            // No speed, or after a gap (tunnel, sleep): the straight line, unless no train could have made it,
            // e.g. a bad fix after a tunnel.
            let step = current.position.distance(to: position)
            if step / (max(seconds, 1) / 3600) < 350 { current.distance += step }
        }
        current.position = position
        current.last = date
        current.topSpeed = max(current.topSpeed, status.speed ?? 0)
        current.status = status
        current.sampler.record(status, distance: current.distance, at: date.timeIntervalSince(current.start))
        ongoing = current
        return finished
    }

    /// Ends a trip not heard from in 20 minutes: the user got off while the Wi-Fi was gone. Kept for a few hours
    /// in case the same ride comes back, e.g. after the lid was closed.
    public mutating func finishIfIdle(at date: Date) -> Trip? {
        guard let ongoing, date.timeIntervalSince(ongoing.last) > 20 * 60 else { return nil }
        let trip = finish()
        paused = ongoing
        return trip
    }

    /// Whether `status` is the ride `paused` was recording: the same train, to the same last stop, on the same
    /// timetable where the trip began. The next train on a line, or one going back the other way, often has the
    /// same name on regional portals. A portal without times there can't tell runs apart, so the ride is split.
    static func sameRun(_ paused: Ongoing, _ status: TrainStatus, at date: Date) -> Bool {
        guard date.timeIntervalSince(paused.last) <= resumeWithin, let train = status.trainName,
              TrainName.same(paused.train, train), let last = status.stops.last?.name, last == paused.status.stops.last?.name,
              let before = paused.status.stops.first(where: { $0.name == paused.from }),
              let time = before.scheduledDeparture ?? before.scheduledArrival,
              let now = status.stops.first(where: { $0.name == paused.from })
        else { return false }
        return time == (now.scheduledDeparture ?? now.scheduledArrival)
    }

    /// The trip on board so far, for the live chart.
    public var current: Trip? { ongoing?.trip }

    /// Ends the trip at the stop closest to where the train was last seen.
    public mutating func finish() -> Trip? {
        paused = nil
        guard let current = ongoing else { return nil }
        ongoing = nil
        guard current.distance >= Self.minimumDistance, current.last.timeIntervalSince(current.start) >= Self.minimumDuration
        else { return nil }
        return current.trip
    }
}

/// All recorded trips, newest first, with the totals the History tab shows.
public struct TripLog: Codable, Sendable, Equatable {
    public private(set) var trips: [Trip] = []

    public init() {}

    /// Adds a trip, or updates it in place when an earlier part of it was logged before the ride went on.
    public mutating func add(_ trip: Trip) {
        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[index] = trip
        } else {
            trips.insert(trip, at: 0)
        }
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
