import Foundation

/// Where the user gets on and off the followed train, and the train they change to.
public struct JourneyPlan: Codable, Sendable, Equatable {
    /// The plan belongs to this train; it's dropped when another train is followed.
    public var trainName: String
    public var boardingStopID: String?
    public var destinationStopID: String?
    public var connection: Connection?

    public init(trainName: String, boardingStopID: String? = nil, destinationStopID: String? = nil, connection: Connection? = nil) {
        self.trainName = trainName
        self.boardingStopID = boardingStopID
        self.destinationStopID = destinationStopID
        self.connection = connection
    }
}

/// The train to change to at the destination.
public struct Connection: Codable, Sendable, Equatable {
    public var tripID: String
    public var name: String
    public var headsign: String?
    public var station: String
    public var scheduledDeparture: Date?
    public var expectedDeparture: Date?
    public var track: String?
    public var cancelled: Bool
    /// Where the user is headed with this train, e.g. "Wunstorf".
    public var finalStop: String?
    public var finalArrival: Date?
    /// Set when the connection came from the ICE portal; it's refreshed from there while on board.
    public var portalStationID: String?

    public init(
        tripID: String, name: String, headsign: String?, station: String,
        scheduledDeparture: Date?, expectedDeparture: Date?, track: String?, cancelled: Bool = false,
        finalStop: String? = nil, finalArrival: Date? = nil, portalStationID: String? = nil
    ) {
        self.tripID = tripID
        self.name = name
        self.headsign = headsign
        self.station = station
        self.scheduledDeparture = scheduledDeparture
        self.expectedDeparture = expectedDeparture
        self.track = track
        self.cancelled = cancelled
        self.finalStop = finalStop
        self.finalArrival = finalArrival
        self.portalStationID = portalStationID
    }

    public init(_ departure: TransitousClient.Departure, at station: String) {
        self.init(
            tripID: departure.tripID, name: departure.displayName, headsign: departure.headsign, station: station,
            scheduledDeparture: departure.scheduled, expectedDeparture: departure.expected,
            track: departure.track, cancelled: departure.cancelled
        )
    }

    public var departure: Date? { expectedDeparture ?? scheduledDeparture }

    public var delayMinutes: Int? {
        guard let scheduledDeparture, let expectedDeparture else { return nil }
        return minutes(from: scheduledDeparture, to: expectedDeparture)
    }

    public enum Transfer: Equatable, Sendable {
        case comfortable(minutes: Int)
        case tight(minutes: Int)
        case atRisk(minutes: Int)
        case cancelled
    }

    /// How much time is left to change trains after arriving at `arrival`.
    public func transfer(after arrival: Date?) -> Transfer? {
        if cancelled { return .cancelled }
        guard let arrival, let departure else { return nil }
        let gap = Int((departure.timeIntervalSince(arrival) / 60).rounded(.down))
        if gap >= 5 { return .comfortable(minutes: gap) }
        if gap >= 2 { return .tight(minutes: gap) }
        return .atRisk(minutes: gap)
    }
}

public struct NotificationSettings: Codable, Sendable, Equatable {
    /// Minutes before arriving at the destination.
    public var arrivalReminders: Set<Int> = [15, 5]
    /// Smallest delay change worth a notification, in minutes.
    public var delayThreshold = 3
    public var trackChanges = true
    public var connectionAlerts = true

    public static let reminderChoices = [30, 15, 10, 5, 2]
    public static let thresholdChoices = [1, 3, 5, 10]

    public init() {}
}

public enum JourneyEvent: Equatable, Sendable {
    case arrivingSoon(stop: String, minutes: Int, track: String?)
    case delayChanged(stop: String, from: Int, to: Int)
    case trackChanged(stop: String, from: String, to: String)
    case connectionDelayChanged(name: String, from: Int, to: Int)
    case connectionTrackChanged(name: String, from: String, to: String)
    case transferChanged(name: String, Connection.Transfer)
}

/// Compares two snapshots of a followed train and reports what's worth a notification.
public enum JourneyWatcher {
    public static func events(
        old: TrainStatus, oldTime: Date, oldConnection: Connection?,
        new: TrainStatus, newTime: Date, newConnection: Connection?,
        plan: JourneyPlan, settings: NotificationSettings = NotificationSettings()
    ) -> [JourneyEvent] {
        var events: [JourneyEvent] = []

        func stop(_ id: String?, in status: TrainStatus) -> Stop? {
            status.stops.first { $0.id == id }
        }

        // Before boarding: departure delay and track at the boarding stop.
        if let before = stop(plan.boardingStopID, in: old), let after = stop(plan.boardingStopID, in: new), !after.passed {
            events += changes(before: before, after: after, departure: true, settings: settings)
        }

        if let before = stop(plan.destinationStopID, in: old), let after = stop(plan.destinationStopID, in: new), !after.passed {
            events += changes(before: before, after: after, departure: false, settings: settings)

            // One notification per reminder whose threshold was crossed since the last update.
            if let oldArrival = before.arrival, let newArrival = after.arrival, newArrival > newTime {
                let reminder = settings.arrivalReminders.sorted().first { minutes in
                    let threshold = TimeInterval(minutes * 60)
                    return oldArrival.timeIntervalSince(oldTime) > threshold && newArrival.timeIntervalSince(newTime) <= threshold
                }
                if let reminder {
                    events.append(.arrivingSoon(stop: after.name, minutes: reminder, track: after.track))
                }
            }

            if settings.connectionAlerts, let oldConnection, let newConnection, oldConnection.tripID == newConnection.tripID {
                if let from = oldConnection.delayMinutes, let to = newConnection.delayMinutes, abs(to - from) >= settings.delayThreshold {
                    events.append(.connectionDelayChanged(name: newConnection.name, from: from, to: to))
                }
                if settings.trackChanges, let from = oldConnection.track, let to = newConnection.track, from != to {
                    events.append(.connectionTrackChanged(name: newConnection.name, from: from, to: to))
                }
                let oldTransfer = oldConnection.transfer(after: before.arrival)
                let newTransfer = newConnection.transfer(after: after.arrival)
                if let newTransfer, severity(newTransfer) > severity(oldTransfer) {
                    events.append(.transferChanged(name: newConnection.name, newTransfer))
                }
            }
        }
        return events
    }

    private static func changes(before: Stop, after: Stop, departure: Bool, settings: NotificationSettings) -> [JourneyEvent] {
        var events: [JourneyEvent] = []
        let delay = { (stop: Stop) -> Int? in
            if departure, let s = stop.scheduledDeparture, let e = stop.expectedDeparture { return minutes(from: s, to: e) }
            return stop.delayMinutes
        }
        if let from = delay(before), let to = delay(after), abs(to - from) >= settings.delayThreshold {
            events.append(.delayChanged(stop: after.name, from: from, to: to))
        }
        if settings.trackChanges, let from = before.track, let to = after.track, from != to {
            events.append(.trackChanged(stop: after.name, from: from, to: to))
        }
        return events
    }

    private static func severity(_ transfer: Connection.Transfer?) -> Int {
        switch transfer {
        case .comfortable, nil: 0
        case .tight: 1
        case .atRisk: 2
        case .cancelled: 3
        }
    }
}

extension TransitousClient {
    /// Direct trains from `station` (where the followed train arrives) to `target`, departing after `arrival`.
    /// S-Bahn and regional trains are only included when `regional` is set.
    public func connections(from station: Station, to target: Station, after arrival: Date, regional: Bool) async throws -> [Connection] {
        var modes = ["HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL"]
        if regional { modes += ["REGIONAL_FAST_RAIL", "REGIONAL_RAIL", "SUBURBAN"] }
        var url = Transitous.base.appending(path: "v6/plan")
        url.append(queryItems: [
            URLQueryItem(name: "fromPlace", value: station.id),
            URLQueryItem(name: "toPlace", value: target.id),
            URLQueryItem(name: "time", value: arrival.formatted(.iso8601)),
            URLQueryItem(name: "numItineraries", value: "6"),
            URLQueryItem(name: "maxTransfers", value: "0"),
            URLQueryItem(name: "directModes", value: ""),
            URLQueryItem(name: "transitModes", value: modes.joined(separator: ",")),
        ])
        return try Self.parseConnections(await loader(url), station: station.name)
    }

    static func parseConnections(_ data: Data, station: String) throws -> [Connection] {
        struct Plan: Decodable { let itineraries: [Itinerary] }
        struct Itinerary: Decodable { let legs: [Leg] }
        struct Leg: Decodable {
            let mode: String
            let tripId: String?
            let displayName: String?
            let headsign: String?
            let cancelled: Bool?
            let from: Transitous.Place
            let to: Transitous.Place
        }

        var seen = Set<String>()
        return try JSONDecoder.portal.decode(Plan.self, from: data).itineraries.compactMap { itinerary in
            let rides = itinerary.legs.filter { $0.mode != "WALK" }
            guard rides.count == 1, let leg = rides.first, let tripID = leg.tripId, seen.insert(tripID).inserted else { return nil }
            return Connection(
                tripID: tripID,
                name: leg.displayName ?? "?",
                headsign: leg.headsign.map(StationName.tidy),
                station: station,
                scheduledDeparture: leg.from.scheduledDeparture,
                expectedDeparture: leg.from.departure,
                track: leg.from.track ?? leg.from.scheduledTrack,
                cancelled: leg.cancelled ?? false,
                finalStop: StationName.tidy(leg.to.name),
                finalArrival: leg.to.arrival ?? leg.to.scheduledArrival
            )
        }
    }

    /// Re-fetches a connecting train and reads its departure at `station`.
    public func refresh(_ connection: Connection) async throws -> Connection {
        var url = Transitous.base.appending(path: "v6/trip")
        url.append(queryItems: [URLQueryItem(name: "tripId", value: connection.tripID)])
        let status = try Transitous.parse(trip: await loader(url), now: Date())
        let wanted = Transitous.normalize(connection.station)
        guard let stop = status.stops.first(where: { Transitous.normalize($0.name) == wanted }) else { return connection }
        var updated = connection
        updated.scheduledDeparture = stop.scheduledDeparture ?? connection.scheduledDeparture
        updated.expectedDeparture = stop.expectedDeparture
        updated.track = stop.track ?? connection.track
        return updated
    }
}
