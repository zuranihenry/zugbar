import Foundation
import Observation
import ZugbarCore

/// Where the user gets on and off and the connection after that, with the notifications about them.
/// Changing to the connection itself is up to `TrainMonitor`, which decides what is followed.
@MainActor
@Observable
final class Journey {
    var plan: JourneyPlan? = Journey.load(JourneyPlan.self, key: "journeyPlan") {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(plan), forKey: "journeyPlan") }
    }
    var notificationSettings = Journey.load(NotificationSettings.self, key: "notificationSettings") ?? NotificationSettings() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(notificationSettings), forKey: "notificationSettings") }
    }
    let connections: ConnectionSearch
    let coaches = CoachSectors()
    let seatEditor = SeatEditor()

    /// The status notifications compare the next one with.
    @ObservationIgnored var lastSnapshot: (status: TrainStatus, time: Date, connection: Connection?)? {
        didSet {
            // Another train or plan: start over with what was notified.
            if lastSnapshot == nil {
                notifiedDelays = [:]
                sentReminders = []
            }
        }
    }
    /// The delay last notified per stop and connection; see JourneyWatcher.
    @ObservationIgnored private var notifiedDelays: [String: Int] = [:]
    /// Reminders already sent, so a delay or a source switch crossing the same mark again doesn't repeat them.
    @ObservationIgnored private var sentReminders: Set<String> = []
    @ObservationIgnored private var connectionRefreshed: Date?
    private let client: TransitousClient
    private let status: () -> TrainStatus?
    private let now: () -> Date
    /// Called when a plan is set, to ask for notification permission.
    private let planSet: () -> Void
    /// Not for the demo train, which DB doesn't know.
    private let loadsCoaches: () -> Bool

    /// `snapshot`: a plan for rendering screenshots, instead of the saved one.
    init(
        snapshot: JourneyPlan?? = nil, client: TransitousClient, status: @escaping () -> TrainStatus?, now: @escaping () -> Date,
        planSet: @escaping () -> Void, loadsCoaches: @escaping () -> Bool
    ) {
        // Before everything else is set, so it doesn't count as a change to save.
        if let snapshot { plan = snapshot }
        self.client = client
        self.status = status
        self.now = now
        self.planSet = planSet
        self.loadsCoaches = loadsCoaches
        var destination: () -> Stop? = { nil }
        connections = ConnectionSearch(client: client) { .init(destination: destination(), now: now()) }
        destination = { [unowned self] in self.destination }
    }

    var destination: Stop? { status()?.stops.first { $0.id == plan?.destinationStopID } }
    var boarding: Stop? { status()?.stops.first { $0.id == plan?.boardingStopID } }

    func toggleDestination(_ stop: Stop) {
        update { plan in
            plan.pendingDestination = nil
            if plan.destinationStopID == stop.id {
                plan.destinationStopID = nil
                plan.connection = nil
            } else {
                plan.destinationStopID = stop.id
                if plan.connection?.station != stop.name { plan.connection = nil }
            }
        }
        connections.isAdding = false
    }

    func toggleBoarding(_ stop: Stop) {
        update { plan in
            plan.pendingBoarding = nil
            plan.boardingStopID = plan.boardingStopID == stop.id ? nil : stop.id
        }
    }

    func chooseConnection(_ connection: Connection) {
        update { $0.connection = connection }
        connections.isAdding = false
    }

    func removeConnection() {
        update { $0.connection = nil }
    }

    /// The user's coach on the followed train, or with `connection` on the train they change to.
    func setSeat(_ seat: Seat?, connection: Bool = false) {
        update { plan in
            if connection { plan.connection?.seat = seat } else { plan.seat = seat }
        }
        refreshCoaches()
    }

    /// Where the user's coach stops: at the boarding stop and destination, and where the connection leaves.
    func refreshCoaches() {
        guard loadsCoaches(), let plan, let train = status()?.trainName else { return }
        let now = now()
        if plan.seat != nil {
            for stop in [boarding, destination].compactMap({ $0 }) where !stop.cancelled {
                coaches.load(train: train, at: stop, departure: stop.scheduledDeparture, track: stop.track, now: now)
            }
        }
        // The connection leaves from the station the followed train gets to, but from its own track.
        if let connection = plan.connection, connection.seat != nil, let destination {
            coaches.load(train: connection.name, at: destination, departure: connection.scheduledDeparture,
                         track: connection.track, now: now)
        }
    }

    /// The followed train's coach sequence at `stop`, or the connection's where it leaves.
    func coachSequence(at stop: Stop, connection: Connection? = nil) -> CoachSequence? {
        if let connection {
            return coaches.sequence(train: connection.name, at: stop, departure: connection.scheduledDeparture, track: connection.track)
        }
        guard let train = status()?.trainName else { return nil }
        return coaches.sequence(train: train, at: stop, departure: stop.scheduledDeparture, track: stop.track)
    }

    func clear() { plan = nil }

    /// Changes the plan for the train shown; an empty plan is dropped.
    func update(_ change: (inout JourneyPlan) -> Void) {
        let status = status()
        guard let trainName = status?.trainName else { return }
        var updated = plan ?? JourneyPlan(trainName: trainName)
        change(&updated)
        updated.updated = now()
        let isEmpty = updated.boardingStopID == nil && updated.destinationStopID == nil && updated.connection == nil
            && updated.pendingBoarding == nil && updated.pendingDestination == nil
        plan = isEmpty ? nil : updated
        if !isEmpty { planSet() }
        lastSnapshot = status.map { ($0, now(), plan?.connection) }
    }

    /// Keeps the plan in step with a new status of the followed train: dropped for another train, stops matched
    /// by name or moved between portal and online stop IDs for the same one.
    func follow(_ newStatus: TrainStatus, previous: TrainStatus?) {
        // A portal briefly reporting no train name shouldn't throw away the plan, nor should
        // another spelling of the same train ("ICE1356", "ICE 1356").
        guard let plan, let name = newStatus.trainName else { return }
        if !TrainName.same(plan.trainName, name) {
            self.plan = nil
        } else {
            var updated = plan.resolved(in: newStatus)
            if let old = previous ?? lastSnapshot?.status { updated = updated.remapped(from: old, to: newStatus) }
            if updated != plan { self.plan = updated }
        }
    }

    func notifyChanges(to newStatus: TrainStatus, strings: Strings) {
        defer { lastSnapshot = (newStatus, Date(), plan?.connection) }
        guard var plan, let last = lastSnapshot, last.status.trainName == newStatus.trainName else { return }
        let events = plan.withoutRepeatedWarnings(JourneyWatcher.events(
            old: last.status, oldTime: last.time, oldConnection: last.connection,
            new: newStatus, newTime: Date(), newConnection: plan.connection, plan: plan,
            settings: notificationSettings, delays: &notifiedDelays
        )).filter { event in
            switch event {
            case .arrivingSoon(let stop, let minutes, _): sentReminders.insert("arrival:\(stop):\(minutes)").inserted
            case .departingSoon(let stop, let minutes, _): sentReminders.insert("departure:\(stop):\(minutes)").inserted
            default: true
            }
        }
        if plan != self.plan { self.plan = plan }
        let destination = newStatus.stops.first { $0.id == plan.destinationStopID }
        for event in events {
            var (title, body) = strings.notification(event)
            if let connection = plan.connection, let destination {
                switch event {
                // The arrival reminder is the moment to think about the connection, so mention it.
                case .arrivingSoon:
                    body = [body, strings.connectionSummary(connection, arrival: destination.arrival)].compactMap { $0 }.joined(separator: " · ")
                // What the change looks like now, without opening the menu bar.
                case .transferChanged:
                    body = [body, strings.transferDetails(connection, arrival: destination.arrival)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                default: break
                }
            }
            Notifier.post(title: title, body: body)
        }
    }

    /// Connections come from Transitous, so check them every few minutes, and about once a minute close to the change.
    func refreshConnectionIfNeeded() {
        let now = now()
        let interval = Connection.refreshInterval(arrival: destination?.arrival, now: now)
        // Transitous trips only: not the demo connection or one an older version took from the ICE portal.
        guard let connection = plan?.connection, connection.portalStationID == nil,
              connectionRefreshed.map({ now.timeIntervalSince($0) > interval }) ?? true
        else { return }
        connectionRefreshed = now
        Task {
            guard var updated = try? await client.refresh(connection), plan?.connection?.tripID == updated.tripID else { return }
            // The coach may have been entered while this was loading.
            updated.seat = plan?.connection?.seat
            plan?.connection = updated
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
