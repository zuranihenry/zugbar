import Foundation

/// A connection as DB Navigator shares it as text: the trains in order, with where and when the user gets on
/// and off each.
///
///     Astadt Hbf → Cstadt
///     01.02.2026
///
///     RE 1 (4567)
///     Nach Dstadt
///     Ab 10:00 Astadt Hbf, Gleis 1 A-C
///     An 11:00 Bstadt, Gleis 2
///
///     RB 2 (8901)
///     …
///
/// Read from the text alone, so it works without network; the trips behind the trains are looked up later.
public struct SharedJourney: Equatable, Sendable {
    public struct Leg: Equatable, Sendable {
        /// As written, "RE 1 (4567)".
        public var train: String
        public var headsign: String?
        public var from: String
        public var departure: Date
        public var departureTrack: String?
        public var to: String
        public var arrival: Date

        public init(train: String, headsign: String? = nil, from: String, departure: Date, departureTrack: String? = nil,
                    to: String, arrival: Date) {
            self.train = train
            self.headsign = headsign
            self.from = from
            self.departure = departure
            self.departureTrack = departureTrack
            self.to = to
            self.arrival = arrival
        }
    }

    /// The trains only: a walk or a bus between two of them is left out, and the next train starts where it starts.
    public var legs: [Leg]

    public init(legs: [Leg]) {
        self.legs = legs
    }

    /// Nil for text that isn't such a connection, or has no train in it. Its times are the clock's in `timeZone`;
    /// without a date line the journey is taken to start today.
    public init?(text: String, now: Date = Date(), timeZone: TimeZone = .current) {
        // Pasted text can be anything; a shared connection is a few hundred characters.
        guard text.utf8.count < 20_000 else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var day = calendar.dateComponents([.year, .month, .day], from: now)
        if let date = lines.lazy.compactMap({ Self.groups(#"^(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})$"#, in: $0) }).first,
           let written = Int(date[2]) {
            day = DateComponents(year: written < 100 ? 2000 + written : written, month: Int(date[1]), day: Int(date[0]))
        }
        guard let midnight = calendar.date(from: day) else { return nil }

        // Each time is the next the clock shows after the one before, so a journey can run past midnight.
        var time = midnight.addingTimeInterval(-1)
        func next(_ clock: [String]) -> Date? {
            guard let hour = Int(clock[0]), let minute = Int(clock[1]), hour < 24, minute < 60,
                  let date = calendar.nextDate(after: time, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                               matchingPolicy: .nextTime)
            else { return nil }
            time = date.addingTimeInterval(-1)
            return date
        }

        var legs: [Leg] = []
        for index in lines.indices.dropLast() {
            guard let from = Self.groups(#"^Ab (\d{1,2}):(\d{2}) (.+?)(?:, Gleis (.+))?$"#, in: lines[index]),
                  let to = Self.groups(#"^An (\d{1,2}):(\d{2}) (.+?)(?:, Gleis (.+))?$"#, in: lines[index + 1]),
                  let departure = next(from), let arrival = next(to)
            else { continue }
            // Above the departure: the train, and usually where it's headed.
            var above = index - 1
            var headsign: String?
            if above >= 0, let towards = Self.groups(#"^Nach (.+)$"#, in: lines[above]) {
                headsign = StationName.tidy(towards[0])
                above -= 1
            }
            guard above >= 0, let train = Self.groups(#"^(\p{L}{1,5}) ?\d{0,5}(?: \(\d{1,6}\))?$"#, in: lines[above]),
                  CalendarJourney.railProducts.contains(train[0].uppercased())
            else { continue }
            legs.append(Leg(
                train: lines[above], headsign: headsign, from: StationName.tidy(from[2]), departure: departure,
                // "4 A-C": the track, then where on it the train stops.
                departureTrack: from[3].split(separator: " ").first.map(String.init),
                to: StationName.tidy(to[2]), arrival: arrival
            ))
        }
        guard !legs.isEmpty else { return nil }
        self.legs = legs
    }

    /// The capture groups of `pattern` when it matches the whole of `text`; a group that took no part is empty.
    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}

extension SharedJourney.Leg {
    /// The leg as a train to change to. Known by its name and times only until its trip is found.
    public var connection: Connection {
        var connection = Connection(
            tripID: "\(Connection.sharedMarker):\(train)@\(Int(departure.timeIntervalSince1970))", name: train, headsign: headsign,
            station: from, scheduledDeparture: departure, expectedDeparture: nil, track: departureTrack,
            finalStop: to, finalArrival: arrival, portalStationID: Connection.sharedMarker
        )
        connection.scheduledFinalArrival = arrival
        return connection
    }
}

extension Connection {
    static let sharedMarker = "shared"

    /// Read from a shared connection, and its trip not found yet.
    public var isShared: Bool { portalStationID == Self.sharedMarker }

    /// A shared connection as the trip the station's departure board has for it, with that trip's live times.
    public func resolved(with departure: TransitousClient.Departure) -> Connection {
        var resolved = self
        resolved.tripID = departure.tripID
        // "RE 1 (4567)" as shared says more than the board's "RE 1": other sources know the train by that number.
        if name.contains("(") == departure.displayName.contains("(") || !TrainName.same(name, departure.displayName) {
            resolved.name = departure.displayName
        }
        resolved.headsign = departure.headsign ?? headsign
        resolved.scheduledDeparture = departure.scheduled ?? scheduledDeparture
        resolved.expectedDeparture = departure.expected
        resolved.track = departure.track ?? track
        resolved.cancelled = departure.cancelled
        resolved.portalStationID = nil
        return resolved
    }
}

extension SharedJourney {
    /// The journey's train that `status` shows, with where the user gets on and off it in the train's own stop
    /// list: the train by name, or one named differently that calls at both stops at the journey's very times.
    func leg(on status: TrainStatus, now: Date) -> (index: Int, boarding: Stop?, destination: Stop)? {
        for (index, leg) in legs.enumerated() {
            let boarding = status.stops.first { StationName.same($0.name, leg.from) }
            // After where the user gets on; a ring line calls twice at some stops.
            let start = boarding.flatMap { stop in status.stops.firstIndex { $0.id == stop.id } }.map { $0 + 1 } ?? 0
            guard let destination = status.stops[start...].first(where: { StationName.same($0.name, leg.to) }),
                  !destination.cancelled, !destination.passed, (destination.arrival ?? leg.arrival) > now,
                  let planned = destination.scheduledArrival ?? destination.arrival
            else { continue }
            let gap = abs(planned.timeIntervalSince(leg.arrival))
            let named = status.trainName.map { TrainName.same(leg.train, $0) } == true
            // The same train number runs again tomorrow, and on some lines every hour.
            if named, gap <= 30 * 60 { return (index, boarding, destination) }
            if gap < 60, let left = boarding?.scheduledDeparture, abs(left.timeIntervalSince(leg.departure)) < 60 {
                return (index, boarding, destination)
            }
        }
        return nil
    }

    /// The plan for the train `status` shows, when it's one of the journey's: off where the journey says, then
    /// its remaining trains. The coach and the time on board carry over from `previous`, the plan for that train.
    public func plan(on status: TrainStatus, previous: JourneyPlan?, now: Date) -> JourneyPlan? {
        guard let name = status.trainName, let (index, boarding, destination) = leg(on: status, now: now) else { return nil }
        let previous = previous.flatMap { TrainName.same($0.trainName, name) ? $0 : nil }
        var plan = JourneyPlan(trainName: name, boardingStopID: previous?.boardingStopID ?? boarding?.id,
                               destinationStopID: destination.id)
        plan.route = legs[(index + 1)...].map(\.connection)
        plan.seat = previous?.seat
        plan.boarded = previous?.boarded
        plan.plannedArrival = legs.last?.arrival
        plan.updated = now
        return plan
    }

    /// For a journey none of whose trains is followed yet: its first train still to arrive, and the plan to
    /// follow the journey from there. Nil once the last one is due in.
    public func start(at now: Date) -> (train: Connection, plan: JourneyPlan)? {
        guard let index = legs.firstIndex(where: { $0.arrival > now }) else { return nil }
        let train = legs[index].connection
        var plan = Handover.plan(after: train, now: now)
        plan.route = legs[(index + 1)...].map(\.connection)
        plan.plannedArrival = legs.last?.arrival
        return (train, plan)
    }
}

extension TransitousClient {
    /// The trip of a train known by name, where and when it leaves, from that station's departure board.
    public func departure(for connection: Connection) async throws -> Departure? {
        guard let time = connection.scheduledDeparture,
              let station = try await stations(matching: connection.station).first
        else { return nil }
        // Trains only, and just the minutes around it: train Wi-Fi may be capped.
        let departures = try await departures(from: station, at: time.addingTimeInterval(-2 * 60), count: 30, railOnly: true)
        return Handover.departure(for: connection, in: departures)
    }
}
