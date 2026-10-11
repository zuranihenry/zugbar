import Foundation
import MapKit
import Network
import Observation
import SwiftUI
import ZugbarCore

@MainActor
@Observable
final class TrainMonitor {
    enum ManualTarget: Codable, Equatable {
        case name(String)
        case trip(id: String, label: String)

        var label: String {
            switch self {
            case .name(let name): name
            case .trip(_, let label): label
            }
        }

        init(_ target: Handover.Target) {
            switch target {
            case .name(let name): self = .name(name)
            case .trip(let id, let label): self = .trip(id: id, label: label)
            }
        }
    }

    enum LookupMessage: Equatable {
        case lookingUp(String), notRunning(String), tripEnded, unreachable
    }

    enum Tracking { case onBoard, online, demo }

    private(set) var status: TrainStatus?
    /// Where the map draws the train; glides between updates instead of jumping.
    private(set) var trainPosition: Coordinate?
    let map = MapState()
    let picker: StationSearch
    let estimates = SpeedEstimator()
    let journey: Journey
    let trips = TripStore()
    private(set) var lastUpdate: Date?
    private(set) var lastError: String?
    private(set) var notificationPermission: Notifier.Permission?
    let updates = UpdateChecker()
    /// Set by "stop tracking" on board; cleared when the network changes.
    private var onBoardDismissed = false

    private(set) var displaySpeed: Int?
    private(set) var topSpeed = 0
    private(set) var now = Date()
    private(set) var lookupMessage: LookupMessage?

    var demoMode = false {
        didSet { if demoMode != oldValue { restart() } }
    }

    /// Followed online when no on-board portal answers. On-board data always takes precedence.
    var manualTarget: ManualTarget? = TrainMonitor.loadTarget() {
        didSet {
            guard manualTarget != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(manualTarget), forKey: "manualTarget")
            if restartsOnTargetChange { restart() }
        }
    }
    @ObservationIgnored private var restartsOnTargetChange = true
    /// The train the user changed from at the plan's destination. Its portal is ignored for a while,
    /// so the Wi-Fi still reaching the platform doesn't pull tracking back to it.
    @ObservationIgnored private var leftTrain: (name: String, at: Date)?
    /// The last train tracked on board. When its portal goes away mid-trip it's followed online instead,
    /// until its portal answers again or its trip is over.
    @ObservationIgnored private var onBoardTrain: (name: String, until: Date)?
    /// While following the on-board train online, its portal is checked about once a minute.
    @ObservationIgnored private var portalProbed = Date.distantPast

    var trainDraft = ""

    private(set) var history = TrainMonitor.loadHistory() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "history") }
    }
    /// Track shape for on-board trains, whose portals only list the stops. Borrowed from Transitous once per train.
    private var onBoardRoutes: [String: Route] = [:]
    private var onBoardRouteRequests: Set<String> = []
    /// When loading a route failed, e.g. because the train Wi-Fi had no internet yet; retried after two minutes.
    private var onBoardRouteFailures: [String: Date] = [:]

    private var provider: (any TrainProvider)?
    private var failures = 0
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let client: TransitousClient

    /// The parts get the monitor through a weak box: closures can't capture `self` before it's initialized.
    /// Snapshot values are set here rather than in the convenience init, so they don't trigger saving.
    private init(snapshot plan: JourneyPlan??, history: TrainHistory?, demo: Bool) {
        let client = TransitousClient()
        let box = WeakBox<TrainMonitor>()
        self.client = client
        if let history { self.history = history }
        demoMode = demo
        picker = StationSearch(client: client) { box.value?.status == nil }
        journey = Journey(
            snapshot: plan, client: client, status: { box.value?.status }, now: { box.value?.now ?? Date() },
            portal: { box.value?.provider as? ICEPortal }, planSet: { box.value?.askForNotifications() }
        )
        box.value = self
    }

    convenience init() {
        self.init(snapshot: nil, history: nil, demo: CommandLine.arguments.contains("--demo"))
        estimates.loadLearnedSpeeds()
        startTicking()
        startFrames()
        restart()
        // Boarding means joining a new network; look for a portal right away.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.demoMode else { return }
                self.onBoardDismissed = false
                self.restart()
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// A static monitor for rendering screenshots; doesn't poll.
    convenience init(
        snapshot status: TrainStatus?, topSpeed: Int = 0, now: Date = Date(),
        history: TrainHistory = TrainHistory(), plan: JourneyPlan? = nil
    ) {
        self.init(snapshot: .some(plan), history: history, demo: false)
        self.status = status
        self.isSnapshot = true
        self.notificationPermission = .allowed
        self.now = now
        self.displaySpeed = status?.speed
        self.topSpeed = max(topSpeed, status?.speed ?? 0)
    }

    var isOnline: Bool { provider is Transitous }

    var tracking: Tracking? {
        guard status != nil else { return nil }
        if demoMode { return .demo }
        return isOnline ? .online : .onBoard
    }

    /// Stops whatever is being shown: online following, demo mode, or (until the network changes) the on-board train.
    func endTracking() {
        switch tracking {
        case .demo: demoMode = false
        case .online: stopTracking()
        case .onBoard:
            trips.finish()
            onBoardDismissed = true
            onBoardTrain = nil
            restart()
        case nil: break
        }
    }

    func refreshNotificationPermission() {
        guard !isSnapshot else { return }
        Task { notificationPermission = await Notifier.permission() }
    }

    /// Screenshot monitors show a finished state instead of asking the system.
    @ObservationIgnored private var isSnapshot = false

    /// A plan was set: notifications are what it's for.
    private func askForNotifications() {
        if notificationPermission != .allowed { requestNotificationPermission() }
    }

    func requestNotificationPermission() {
        Task {
            if notificationPermission == .denied {
                Notifier.openSystemSettings()
            } else {
                _ = await Notifier.requestPermission()
            }
            notificationPermission = await Notifier.permission()
        }
    }

    var isTopSpeed: Bool {
        guard let displaySpeed else { return false }
        return topSpeed > 0 && displaySpeed >= topSpeed
    }

    func refresh() { restart() }

    // MARK: - Manual tracking

    func trackTrain() {
        let name = trainDraft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return manualTarget = nil }
        history.record(.train(name))
        manualTarget = .name(name)
    }

    var suggestions: [TrainHistory.Item] { history.suggestions(at: now) }

    func open(_ item: TrainHistory.Item) {
        switch item {
        case .train(let name):
            trainDraft = name
            trackTrain()
        case .line(let stationID, let stationName, let line):
            picker.choose(TransitousClient.Station(id: stationID, name: stationName), line: line)
        }
    }

    func forget(_ item: TrainHistory.Item) {
        history.remove(item)
    }

    func follow(_ train: LiveTrain) {
        manualTarget = .trip(id: train.tripID, label: train.name)
    }

    func surpriseMe() {
        if let train = picker.liveTrains.randomElement() { follow(train) }
    }

    func follow(_ departure: TransitousClient.Departure) {
        if departure.isRegional, let station = picker.selectedStation {
            history.record(.line(stationID: station.id, stationName: station.name, line: departure.line))
        } else if !departure.isRegional {
            history.record(.train(departure.displayName))
        }
        let label = [departure.displayName, departure.headsign.map { "→ \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
        manualTarget = .trip(id: departure.tripID, label: label)
    }

    func stopTracking() {
        trainDraft = ""
        onBoardTrain = nil
        // Following the on-board train online has no target to clear, so restart explicitly.
        if manualTarget == nil { restart() } else { manualTarget = nil }
    }

    // MARK: - Map position

    /// Last two GPS fixes, to move evenly between them (the marker runs one fix behind).
    @ObservationIgnored private var gpsFixes: [(coordinate: Coordinate, time: Date)] = []
    private var frameTask: Task<Void, Never>?

    /// Recomputes the marker about 30 times a second from the clock, so it moves at a constant pace.
    private func startFrames() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.moveTrain()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func moveTrain() {
        guard let status else {
            if trainPosition != nil { trainPosition = nil }
            return
        }
        let date = Date()
        if let gps = status.position {
            trainPosition = interpolatedGPS(gps, at: date)
        } else {
            trainPosition = estimates.position(of: status, at: date)
        }
        if let trainPosition { map.trainMoved(to: trainPosition, at: date) }
    }

    private func interpolatedGPS(_ latest: Coordinate, at date: Date) -> Coordinate {
        if gpsFixes.last?.coordinate != latest {
            gpsFixes = Array((gpsFixes + [(latest, date)]).suffix(2))
        }
        guard gpsFixes.count == 2 else { return latest }
        let (from, to) = (gpsFixes[0], gpsFixes[1])
        let interval = max(to.time.timeIntervalSince(from.time), 1)
        // Big jumps (first fix, another train) aren't animated.
        guard from.coordinate.distance(to: to.coordinate) < 5 else { return latest }
        let t = min(max(date.timeIntervalSince(to.time) / interval, 0), 1)
        return Coordinate(
            latitude: from.coordinate.latitude + (to.coordinate.latitude - from.coordinate.latitude) * t,
            longitude: from.coordinate.longitude + (to.coordinate.longitude - from.coordinate.longitude) * t
        )
    }

    // MARK: - Debug

    func postTestNotification(_ event: JourneyEvent, withConnection: Bool = false) {
        var (title, body) = strings.notification(event)
        if withConnection {
            let arrival = Date().addingTimeInterval(5 * 60)
            let connection = Connection(tripID: "test", name: "RE 1", headsign: nil, station: "Nürnberg Hbf",
                                        scheduledDeparture: arrival.addingTimeInterval(10 * 60), expectedDeparture: nil, track: "12")
            body = [body, strings.connectionSummary(connection, arrival: arrival)].compactMap { $0 }.joined(separator: " · ")
        }
        Notifier.post(title: title, body: body, force: true)
    }

    func demoAddDelay() { Task { await DemoScenario.shared.addDelay(5) } }
    func demoChangeTrack() { Task { await DemoScenario.shared.changeTrack() } }
    func demoSkipAhead() { Task { await DemoScenario.shared.skipAhead(minutes: 5) } }

    func demoResetScenario() {
        Task { await DemoScenario.shared.reset() }
    }

    /// Sets the stop after next as destination with a made-up connection 8 minutes after arrival.
    func demoPlanJourney() {
        guard let status, let index = status.stops.firstIndex(where: { !$0.passed }) else { return }
        let destination = status.stops[min(index + 1, status.stops.count - 1)]
        let departure = (destination.arrival ?? now).addingTimeInterval(8 * 60)
        let connection = Connection(
            tripID: "demo", name: "RE 1", headsign: "Regensburg Hbf", station: destination.name,
            scheduledDeparture: departure, expectedDeparture: departure, track: "12",
            finalStop: "Regensburg Hbf", portalStationID: "demo"
        )
        journey.update { plan in
            plan.destinationStopID = destination.id
            plan.connection = connection
        }
    }

    func clearHistory() { history = TrainHistory() }

    private var strings: Strings {
        Strings(AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system)
    }

    private static func loadHistory() -> TrainHistory {
        guard let data = UserDefaults.standard.data(forKey: "history"),
              let history = try? JSONDecoder().decode(TrainHistory.self, from: data)
        else { return TrainHistory() }
        return history
    }

    private static func loadTarget() -> ManualTarget? {
        guard let data = UserDefaults.standard.data(forKey: "manualTarget") else { return nil }
        return try? JSONDecoder().decode(ManualTarget.self, from: data)
    }

    // MARK: - Polling

    private func restart() {
        pollTask?.cancel()
        provider = nil
        failures = 0
        lookupMessage = nil
        if demoMode { status = nil; topSpeed = 0 }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            if provider == nil {
                if demoMode {
                    provider = DemoProvider()
                    continue
                } else if await takeOverFromPortal() {
                    // On-board data takes precedence.
                } else if !onBoardDismissed, status?.isOnline == false,
                          Handover.isDue(plan: journey.plan, status: status, now: Date(), leeway: Self.arrivalLeeway) {
                    // The train's Wi-Fi went away as it arrived at the destination: the user is changing trains.
                    followConnection()
                } else if let manualTarget {
                    await lookUp(manualTarget)
                } else if let train = fallbackTrain {
                    portalProbed = Date()
                    await lookUp(.name(train), fallback: true)
                }
            } else if let provider {
                if isOnline, manualTarget == nil, Date().timeIntervalSince(portalProbed) > 60 {
                    portalProbed = Date()
                    if await takeOverFromPortal() {
                        try? await Task.sleep(for: pollInterval)
                        continue
                    }
                }
                do {
                    let next = try await provider.fetch()
                    if !isOnline, isLeftBehind(next) { self.provider = nil } else { apply(next) }
                    lastError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = String(describing: error)
                    handle(error)
                }
            }

            if provider == nil, status != nil { lost() }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Switches to an on-board portal if one answers, other than the train the user changed from.
    private func takeOverFromPortal() async -> Bool {
        guard !onBoardDismissed,
              let (found, first) = await Self.firstResponding(Providers.onBoard(loader: PortalRecorder.wrap(URLSession.portal.loader))),
              !Task.isCancelled, !isLeftBehind(first)
        else { return false }
        provider = found
        // A search from before boarding shouldn't come back once this train's Wi-Fi is gone.
        if let target = manualTarget, let name = first.trainName, !TrainName.same(target.label, name) {
            quietlySetTarget(nil)
        }
        apply(first)
        return true
    }

    /// The on-board train to follow online while its portal doesn't answer, e.g. after the Wi-Fi dropped.
    private var fallbackTrain: String? {
        guard !onBoardDismissed, let onBoardTrain, Date() < onBoardTrain.until else { return nil }
        return onBoardTrain.name
    }

    /// Portals are local and cheap; Transitous is a shared community service.
    private var pollInterval: Duration {
        if provider == nil { return .seconds(manualTarget == nil && fallbackTrain == nil ? 15 : 60) }
        return isOnline ? .seconds(30) : .seconds(3)
    }

    /// `fallback`: following the on-board train whose portal went away; a failed search ends that quietly.
    private func lookUp(_ target: ManualTarget, fallback: Bool = false) async {
        let online = switch target {
        case .name(let name): Transitous(query: name)
        case .trip(let id, let label): Transitous(tripID: id, label: label)
        }
        lookupMessage = .lookingUp(target.label)
        do {
            let first = try await online.fetch()
            guard !Task.isCancelled else { return }
            provider = online
            lookupMessage = nil
            apply(first)
        } catch {
            guard !Task.isCancelled else { return }
            if fallback, let error = error as? Transitous.LookupError {
                onBoardTrain = nil
                lookupMessage = nil
                if error == .tripEnded, Handover.isDueAfterTripEnded(plan: journey.plan, trainName: target.label, now: Date()) {
                    followConnection()
                }
                return
            }
            switch error as? Transitous.LookupError {
            case .notRunning: lookupMessage = .notRunning(target.label)
            case .tripEnded:
                if Handover.isDueAfterTripEnded(plan: journey.plan, trainName: target.label, now: Date()) { return followConnection() }
                lookupMessage = .tripEnded
            case nil: lookupMessage = .unreachable
            }
        }
    }

    private func handle(_ error: Error) {
        failures += 1
        if error as? Transitous.LookupError == .tripEnded {
            onBoardTrain = nil
            if Handover.isDueAfterTripEnded(plan: journey.plan, trainName: status?.trainName, now: Date()) { return followConnection() }
            lost()
            lookupMessage = .tripEnded
            // A picked trip won't run again; a train name might tomorrow.
            if case .trip = manualTarget { manualTarget = nil }
        } else if failures >= 4 {
            if status?.isOnline == false, Handover.isDue(plan: journey.plan, status: status, now: Date(), leeway: Self.arrivalLeeway) {
                return followConnection()
            }
            lost()
        }
    }

    /// Train Wi-Fi often drops while pulling into a station, a little before the timetabled arrival.
    private static let arrivalLeeway: TimeInterval = 3 * 60

    /// Switches to the planned connection after the user changed trains at the destination.
    private func followConnection() {
        guard !demoMode, !findingReplacement, let plan = journey.plan, let connection = plan.connection else { return }
        let arrival = status?.stops.first { $0.id == plan.destinationStopID }?.arrival
        if Handover.isMissed(connection, arrival: arrival) {
            // The connection left before the train got in: take the next train to the same place instead.
            findingReplacement = true
            Task {
                defer { findingReplacement = false }
                let next = await replacement(for: connection, after: arrival ?? Date())
                if let next {
                    Notifier.post(title: strings.connectionMissed, body: strings.nextTrain(next), force: true)
                    journey.plan?.connection = next
                }
                followConnection()
            }
            return
        }
        leftTrain = (plan.trainName, Date())
        onBoardTrain = nil
        journey.plan = Handover.plan(after: connection)
        journey.lastSnapshot = nil
        let target = Handover.target(for: connection)
        quietlySetTarget(ManualTarget(target))
        restart()
        if case .name = target { findTrip(of: connection) }
    }

    @ObservationIgnored private var findingReplacement = false

    /// The earliest direct train after `connection` from the same station to the same final stop.
    private func replacement(for connection: Connection, after earliest: Date) async -> Connection? {
        guard let final = connection.finalStop,
              let from = try? await client.stations(matching: connection.station).first,
              let to = try? await client.stations(matching: final).first,
              let options = try? await client.connections(from: from, to: to, after: earliest, regional: true)
        else { return nil }
        guard var next = Handover.replacement(for: connection, in: options, after: earliest) else { return nil }
        next.station = connection.station
        return next
    }

    /// Missed the train, or would rather take a later one: before changing, swaps the planned connection
    /// for the next one; after changing, follows the next train between the same two stops instead.
    func takeNextTrain() {
        guard let plan = journey.plan else { return }
        let leg: Connection
        if let connection = plan.connection {
            leg = connection
        } else if let status, let boarding = status.stops.first(where: { $0.id == plan.boardingStopID }),
                  let final = status.stops.first(where: { $0.id == plan.destinationStopID })?.name ?? plan.pendingDestination {
            let tripID = if case .trip(let id, _) = manualTarget { id } else { "" }
            leg = Connection(tripID: tripID, name: status.trainName ?? "", headsign: nil, station: boarding.name,
                             scheduledDeparture: boarding.departure, expectedDeparture: nil, track: nil, finalStop: final)
        } else {
            return
        }
        let following = plan.connection == nil
        Task {
            guard let next = await replacement(for: leg, after: (leg.departure ?? Date()).addingTimeInterval(60)) else {
                Notifier.post(title: strings.takeNextTrain, body: strings.noNextTrain, force: true)
                return
            }
            Notifier.post(title: strings.nextTrainTitle, body: strings.nextTrain(next), force: true)
            if following {
                journey.plan = Handover.plan(after: next)
                journey.lastSnapshot = nil
                quietlySetTarget(ManualTarget(Handover.target(for: next)))
                restart()
            } else {
                journey.update { $0.connection = next }
            }
        }
    }

    /// Connections from the ICE portal are first searched by name, which only finds long-distance trains.
    /// Looks the train up on the station's departure board to follow it by trip instead.
    private func findTrip(of connection: Connection) {
        let client = client
        Task {
            let time = (connection.scheduledDeparture ?? Date()).addingTimeInterval(-10 * 60)
            guard let station = try? await client.stations(matching: connection.station).first,
                  let departures = try? await client.departures(from: station, at: time, count: 60),
                  let departure = Handover.departure(for: connection, in: departures),
                  manualTarget == .name(connection.name)
            else { return }
            // Takes over Transitous's spelling, so the plan isn't dropped as belonging to another train.
            if let plan = journey.plan, plan.trainName == connection.name { journey.plan?.trainName = departure.displayName }
            let label = [departure.displayName, departure.headsign.map { "→ \($0)" }].compactMap { $0 }.joined(separator: " ")
            manualTarget = .trip(id: departure.tripID, label: label)
        }
    }

    private func isLeftBehind(_ status: TrainStatus) -> Bool {
        guard let leftTrain, let name = status.trainName, Date().timeIntervalSince(leftTrain.at) < 3 * 60 * 60 else { return false }
        return TrainName.same(leftTrain.name, name)
    }

    /// Changes the target from within the poll loop, without restarting it.
    private func quietlySetTarget(_ target: ManualTarget?) {
        restartsOnTargetChange = false
        manualTarget = target
        restartsOnTargetChange = true
    }

    private func apply(_ newStatus: TrainStatus) {
        guard !Task.isCancelled else { return }
        var newStatus = newStatus
        if newStatus.route == nil, !isOnline, !demoMode, let name = newStatus.trainName {
            if let route = onBoardRoutes[name] { newStatus.route = route } else { loadOnBoardRoute(for: name) }
        }
        journey.follow(newStatus, previous: status)
        if !newStatus.isOnline, !demoMode, let name = newStatus.trainName {
            onBoardTrain = (name, Handover.fallbackDeadline(for: newStatus, now: Date()))
        }
        journey.notifyChanges(to: newStatus, strings: strings)
        journey.refreshConnectionIfNeeded(portal: provider as? ICEPortal)
        status = newStatus
        lastUpdate = Date()
        estimates.prepareProfile(for: newStatus)
        if !demoMode {
            estimates.learn(from: newStatus)
            trips.record(newStatus)
        }
        failures = 0
        if newStatus.speed == nil { displaySpeed = nil }
        if Handover.isDue(plan: journey.plan, status: newStatus, now: Date()) { followConnection() }
    }

    private func loadOnBoardRoute(for trainName: String) {
        guard !onBoardRouteRequests.contains(trainName) else { return }
        if let failed = onBoardRouteFailures[trainName], Date().timeIntervalSince(failed) < 120 { return }
        onBoardRouteRequests.insert(trainName)
        Task {
            // Needs the train Wi-Fi to have internet access; without it the map keeps straight lines between stops.
            if let route = try? await Transitous(query: trainName).fetch().route {
                onBoardRoutes[trainName] = route
                onBoardRouteFailures[trainName] = nil
            } else {
                onBoardRouteFailures[trainName] = Date()
            }
            onBoardRouteRequests.remove(trainName)
        }
    }

    private func lost() {
        trips.finish()
        provider = nil
        status = nil
        trainPosition = nil
        displaySpeed = nil
        topSpeed = 0
        // The next train's first fix shouldn't glide from where this one was.
        gpsFixes = []
    }

    nonisolated private static func firstResponding(_ providers: [any TrainProvider]) async -> (any TrainProvider, TrainStatus)? {
        await withTaskGroup(of: (any TrainProvider, TrainStatus)?.self) { group in
            for provider in providers {
                group.addTask {
                    guard let status = try? await provider.fetch() else { return nil }
                    return (provider, status)
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    // MARK: - Display

    /// Eases the shown speed toward the reported one and ticks countdowns.
    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func tick() {
        let date = Date()
        if Int(date.timeIntervalSince1970) != Int(now.timeIntervalSince1970) {
            now = date
            // Picks up the setting being switched on and the train entering a new section without waiting for the next poll.
            if let status { estimates.prepareProfile(for: status) }
            estimates.refreshSection(for: status, at: now)
        }

        guard let target = status?.speed else { return }
        var shown = displaySpeed ?? target
        if abs(shown - target) > 20 {
            shown = target
        } else if shown < target {
            shown += 1
        } else if shown > target {
            shown -= 1
        }
        if shown != displaySpeed { displaySpeed = shown }
        if shown > topSpeed { topSpeed = shown }
    }
}

/// Lets the parts reach the monitor without keeping it alive.
private final class WeakBox<T: AnyObject> {
    weak var value: T?
}
