import Foundation

/// Moving on from the followed train to the planned connection once the user has changed trains.
public enum Handover {
    /// What to follow online after changing: the connection's trip, or its name when it came from the
    /// ICE portal, whose trip IDs Transitous doesn't know.
    public enum Target: Equatable, Sendable {
        case name(String)
        case trip(id: String, label: String)
    }

    /// Whether the followed train has reached the plan's destination, so the connection is next.
    /// `leeway` counts an arrival that close as reached, e.g. when the train Wi-Fi drops as it pulls in.
    public static func isDue(plan: JourneyPlan?, status: TrainStatus?, now: Date, leeway: TimeInterval = 0) -> Bool {
        guard let plan, isCurrent(plan.connection, now: now), let status, let destination = destination(of: plan, in: status)
        else { return false }
        // Online, "passed" only means the timetable says so, and the live times can lag the real train by minutes.
        if status.isOnline {
            guard let arrival = destination.arrival ?? destination.departure else { return false }
            return arrival.addingTimeInterval(onlineGrace) <= now.addingTimeInterval(leeway)
        }
        if destination.passed { return true }
        guard let arrival = destination.arrival else { return false }
        return arrival <= now.addingTimeInterval(leeway)
    }

    /// How long after its expected arrival a train followed online counts as arrived.
    public static let onlineGrace: TimeInterval = 2 * 60

    /// Whether the followed train is `grace` past the plan's destination, with or without a connection:
    /// a destination alone also says where the user gets off.
    public static func hasReached(plan: JourneyPlan?, status: TrainStatus, now: Date, grace: TimeInterval) -> Bool {
        guard let plan, let destination = destination(of: plan, in: status),
              let arrival = destination.arrival ?? destination.departure
        else { return false }
        return arrival.addingTimeInterval(grace) <= now
    }

    /// The plan's destination among the stops of `status`, when it's the planned train and stops there.
    private static func destination(of plan: JourneyPlan, in status: TrainStatus) -> Stop? {
        guard let name = status.trainName, TrainName.same(plan.trainName, name),
              let destination = status.stops.first(where: { $0.id == plan.destinationStopID }), !destination.cancelled
        else { return nil }
        return destination
    }

    /// After the followed train's trip ended, its part of the journey is over too.
    public static func isDueAfterTripEnded(plan: JourneyPlan?, trainName: String?, now: Date) -> Bool {
        guard let plan, isCurrent(plan.connection, now: now), let trainName else { return false }
        return TrainName.same(plan.trainName, trainName)
    }

    /// A plan saved on an earlier day can come back when the same train number runs again;
    /// its connection left long ago and isn't worth following.
    private static func isCurrent(_ connection: Connection?, now: Date) -> Bool {
        guard let connection else { return false }
        guard let departure = connection.departure else { return true }
        return departure > now.addingTimeInterval(-60 * 60)
    }

    /// The plan's connection, when `trainName` is that train: the user changed trains without Zugbar seeing the
    /// first one arrive, e.g. the laptop was closed and woken on the connection, whose portal answered first.
    /// Up to six hours after its departure, as a laptop can stay closed a while.
    public static func boardedConnection(plan: JourneyPlan?, trainName: String?, now: Date) -> Connection? {
        guard let plan, let trainName, let connection = plan.connection, !connection.cancelled,
              !TrainName.same(plan.trainName, trainName), TrainName.same(connection.name, trainName)
        else { return nil }
        if let departure = connection.departure, departure < now.addingTimeInterval(-6 * 60 * 60) { return nil }
        return connection
    }

    public static func target(for connection: Connection) -> Target {
        if connection.portalStationID != nil || connection.tripID.hasPrefix("iceportal:") {
            return .name(connection.name)
        }
        let label = [connection.name, connection.headsign.map { "→ \($0)" }].compactMap { $0 }.joined(separator: " ")
        return .trip(id: connection.tripID, label: label)
    }

    /// Until when an on-board train is followed online after its portal went away mid-trip:
    /// a quarter of an hour after it's due at its last stop, like a trip followed online, or at the plan's
    /// destination if that comes first, as the user gets off there.
    public static func fallbackDeadline(for status: TrainStatus, plan: JourneyPlan? = nil, now: Date) -> Date {
        var end = status.stops.last?.arrival
        if let plan, let destination = destination(of: plan, in: status), let arrival = destination.arrival ?? destination.departure {
            end = min(arrival, end ?? arrival)
        }
        return end.map { $0.addingTimeInterval(15 * 60) } ?? now.addingTimeInterval(60 * 60)
    }

    /// Finds a connection listed by the ICE portal on a Transitous departure board, so it can be followed by
    /// trip; Transitous's name search only knows long-distance trains. Matches the departure time, then the
    /// name or line ("RE 6" and "RE6 (89736)"), or else the category and where the train is headed.
    public static func departure(for connection: Connection, in departures: [TransitousClient.Departure]) -> TransitousClient.Departure? {
        guard let wanted = connection.scheduledDeparture ?? connection.expectedDeparture else { return nil }
        let atTime = departures.filter { departure in
            guard let time = departure.scheduled ?? departure.expected else { return false }
            return abs(time.timeIntervalSince(wanted)) <= 90
        }
        let line = Transitous.normalize(TransitousClient.lineName(from: connection.name))
        if let named = atTime.first(where: {
            TrainName.same($0.displayName, connection.name) || Transitous.normalize($0.line) == line
        }) {
            return named
        }
        let category = Transitous.normalize(connection.name).prefix { $0.isLetter }
        guard !category.isEmpty, let headsign = connection.finalStop ?? connection.headsign else { return nil }
        return atTime.first { departure in
            Transitous.normalize(departure.displayName).prefix { $0.isLetter } == category
                && departure.headsign.map { StationName.same($0, headsign) } == true
        }
    }

    /// Whether the connection leaves before the followed train gets there, so it can't be caught.
    public static func isMissed(_ connection: Connection, arrival: Date?) -> Bool {
        guard !connection.cancelled, let arrival, let departure = connection.departure else { return false }
        return departure < arrival
    }

    /// The train to take instead of a missed one: of the direct trains leaving from `earliest` on, the one that
    /// gets there first. An RE leaving a few minutes after an S-Bahn often overtakes it.
    public static func replacement(for connection: Connection, in options: [Connection], after earliest: Date) -> Connection? {
        options
            .filter { !$0.cancelled && $0.tripID != connection.tripID && ($0.departure ?? .distantPast) >= earliest }
            .min { a, b in
                let (arrivalA, arrivalB) = (a.finalArrival ?? .distantFuture, b.finalArrival ?? .distantFuture)
                return arrivalA != arrivalB ? arrivalA < arrivalB : (a.departure ?? .distantFuture) < (b.departure ?? .distantFuture)
            }
    }

    /// The plan for the connecting train: boarding where the user changes, getting off at the connection's
    /// final stop. Stops are matched by name once the train's own stop list is known.
    public static func plan(after connection: Connection, now: Date = Date()) -> JourneyPlan {
        var plan = JourneyPlan(trainName: connection.name)
        plan.updated = now
        plan.pendingBoarding = connection.station
        plan.pendingDestination = connection.finalStop
        return plan
    }
}

extension JourneyPlan {
    /// Turns pending stop names into stop IDs of `status` and takes over its spelling of the train name.
    /// The destination must come after the boarding stop; names that don't match stay pending.
    public func resolved(in status: TrainStatus) -> JourneyPlan {
        var plan = self
        if let name = status.trainName { plan.trainName = name }
        if let pending = pendingBoarding, plan.boardingStopID == nil,
           let stop = status.stops.first(where: { !$0.cancelled && StationName.same($0.name, pending) }) {
            plan.boardingStopID = stop.id
            plan.pendingBoarding = nil
        }
        if let pending = pendingDestination, plan.destinationStopID == nil {
            let start = status.stops.firstIndex { $0.id == plan.boardingStopID }.map { $0 + 1 } ?? 0
            if let stop = status.stops[start...].first(where: { !$0.cancelled && StationName.same($0.name, pending) }) {
                plan.destinationStopID = stop.id
                plan.pendingDestination = nil
            }
        }
        return plan
    }
}

extension JourneyPlan {
    /// Moves the stop IDs over to `new` when the same train comes from another source, e.g. online after
    /// its portal went away; portals and Transitous name the stops alike but give them different IDs.
    public func remapped(from old: TrainStatus, to new: TrainStatus) -> JourneyPlan {
        guard let oldName = old.trainName, let newName = new.trainName, TrainName.same(oldName, newName) else { return self }
        func counterpart(_ id: String?, after start: Int = 0) -> String? {
            guard let id, !new.stops.contains(where: { $0.id == id }),
                  let stop = old.stops.first(where: { $0.id == id }), start < new.stops.count
            else { return id }
            return new.stops[start...].first { StationName.same($0.name, stop.name) }?.id ?? id
        }
        var plan = self
        plan.boardingStopID = counterpart(boardingStopID)
        let start = new.stops.firstIndex { $0.id == plan.boardingStopID }.map { $0 + 1 } ?? 0
        plan.destinationStopID = counterpart(destinationStopID, after: start)
        return plan
    }
}

public enum TrainName {
    /// Whether two names mean the same train, e.g. "ICE 1356" and "ICE1356", "RE80 (4711)" and "RE 4711",
    /// or a followed trip's label "RE 1 → Nürnberg Hbf" and "RE 1".
    public static func same(_ a: String, _ b: String) -> Bool {
        let (a, b) = (withoutHeadsign(a), withoutHeadsign(b))
        if Transitous.normalize(a) == Transitous.normalize(b) { return true }
        guard let x = number(a), let y = number(b), x.number == y.number else { return false }
        // Long-distance numbers are unique; short ones are line numbers and need the same category too.
        return x.number.count >= 3 || x.category == y.category
    }

    private static func withoutHeadsign(_ name: String) -> String {
        name.split(separator: "→", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
    }

    private static func number(_ name: String) -> (category: String, number: String)? {
        if let number = TrainStatus(provider: "", trainName: name).trainNumber { return number }
        // "ICE1356" without a space.
        let compact = Transitous.normalize(name)
        let category = compact.prefix { $0.isLetter }
        let digits = compact.dropFirst(category.count)
        guard !category.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return (String(category), String(digits))
    }
}

extension StationName {
    /// Whether two feeds name the same station, e.g. "Nürnberg Hauptbahnhof" and "Nürnberg Hbf".
    public static func same(_ a: String, _ b: String) -> Bool {
        Transitous.normalize(tidy(a)) == Transitous.normalize(tidy(b))
    }
}
