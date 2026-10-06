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
    }

    enum LookupMessage: Equatable {
        case lookingUp(String), notRunning(String), tripEnded, unreachable
    }

    enum PickerMessage: Equatable {
        case noStation, loadingDepartures, noDepartures, failed
    }

    enum Tracking { case onBoard, online, demo }

    private(set) var status: TrainStatus?
    /// Map camera; `.automatic` fits the whole route.
    var mapCamera: MapCameraPosition = .automatic
    /// Keeps the map centered on the train as it moves.
    var mapFollowsTrain = false
    private(set) var lastUpdate: Date?
    private(set) var lastError: String?
    private(set) var notificationPermission: Notifier.Permission?
    private(set) var portalConnections: [Connection] = []
    /// Set by "stop tracking" on board; cleared when the network changes.
    private var onBoardDismissed = false

    var notificationSettings = TrainMonitor.load(NotificationSettings.self, key: "notificationSettings") ?? NotificationSettings() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(notificationSettings), forKey: "notificationSettings") }
    }
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
            restart()
        }
    }

    var trainDraft = ""
    var stationQuery = "" {
        didSet { stationQueryChanged() }
    }
    var selectedLine: String?
    private(set) var stations: [TransitousClient.Station] = []
    private(set) var selectedStation: TransitousClient.Station?
    private(set) var departures: [TransitousClient.Departure] = []
    private(set) var pickerMessage: PickerMessage?

    private(set) var history = TrainMonitor.loadHistory() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "history") }
    }
    private(set) var plan: JourneyPlan? = TrainMonitor.load(JourneyPlan.self, key: "journeyPlan") {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(plan), forKey: "journeyPlan") }
    }
    /// The connection search in the destination card is collapsed until the user asks for it.
    var isAddingConnection = false {
        didSet { if isAddingConnection { loadPortalConnections() } else if oldValue { resetConnectionPicker() } }
    }
    var connectionQuery = "" {
        didSet { connectionQueryChanged() }
    }
    private(set) var connectionTargets: [TransitousClient.Station] = []
    private(set) var connectionOptions: [Connection] = []
    private(set) var connectionMessage: PickerMessage?
    private var connectionSearch: Task<Void, Never>?
    private var connectionTarget: TransitousClient.Station?
    private var lastSnapshot: (status: TrainStatus, time: Date, connection: Connection?)?
    private var connectionRefreshed: Date?

    /// Experimental: speed profiles per section from OpenStreetMap speed limits.
    private(set) var profiles: [String: SpeedProfile] = [:]
    private(set) var profileState: ProfileState = .off
    /// Failed sections and when; retried after five minutes.
    private var profileFailures: [String: Date] = [:]
    private var profileRequests: Set<String> = []
    private let overpass = OverpassClient()
    private let limitCache = LimitCache()

    enum ProfileState: Equatable { case off, loading, ready, unavailable }

    private(set) var liveTrains: [LiveTrain] = []
    private var liveTrainsLoaded: Date?

    private var provider: (any TrainProvider)?
    private var failures = 0
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let client = TransitousClient()
    private var searchTask: Task<Void, Never>?

    init() {
        demoMode = CommandLine.arguments.contains("--demo")
        startTicking()
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
    init(
        snapshot status: TrainStatus?, topSpeed: Int = 0, now: Date = Date(),
        history: TrainHistory = TrainHistory(), plan: JourneyPlan? = nil
    ) {
        self.status = status
        self.history = history
        self.plan = plan
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
            onBoardDismissed = true
            restart()
        case nil: break
        }
    }

    func refreshNotificationPermission() {
        Task { notificationPermission = await Notifier.permission() }
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

    var filteredDepartures: [TransitousClient.Departure] {
        guard let selectedLine else { return departures }
        return departures.filter { $0.line == selectedLine }
    }

    var lines: [String] { TransitousClient.lines(in: departures) }

    /// The train that most recently left: if you just boarded, it's probably this one.
    var likelyDeparture: TransitousClient.Departure? {
        filteredDepartures.last { departure in
            guard let time = departure.time, !departure.cancelled else { return false }
            return time <= now && time > now.addingTimeInterval(-30 * 60)
        }
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
            choose(TransitousClient.Station(id: stationID, name: stationName), line: line)
        }
    }

    func forget(_ item: TrainHistory.Item) {
        history.remove(item)
    }

    func follow(_ train: LiveTrain) {
        manualTarget = .trip(id: train.tripID, label: train.name)
    }

    func surpriseMe() {
        if let train = liveTrains.randomElement() { follow(train) }
    }

    /// Refreshes the "live right now" list at most every five minutes.
    func loadLiveTrains() {
        if let loaded = liveTrainsLoaded, Date().timeIntervalSince(loaded) < 300 { return }
        liveTrainsLoaded = Date()
        Task {
            if let trains = try? await client.liveTrains() { liveTrains = trains }
        }
    }

    func follow(_ departure: TransitousClient.Departure) {
        if departure.isRegional, let station = selectedStation {
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
        manualTarget = nil
    }

    func choose(_ station: TransitousClient.Station, line: String? = nil) {
        searchTask?.cancel()
        selectedStation = station
        stations = []
        stationQuery = station.name
        selectedLine = line
        pickerMessage = .loadingDepartures
        Task {
            do {
                // Start half an hour back so a train you've just boarded is still listed.
                departures = try await client.departures(from: station, at: now.addingTimeInterval(-30 * 60), count: 120)
                pickerMessage = departures.isEmpty ? .noDepartures : nil
            } catch {
                pickerMessage = .failed
            }
        }
    }

    func clearStation() {
        searchTask?.cancel()
        selectedStation = nil
        departures = []
        stations = []
        selectedLine = nil
        pickerMessage = nil
        stationQuery = ""
    }

    private func stationQueryChanged() {
        if let selectedStation {
            guard stationQuery != selectedStation.name else { return }
            self.selectedStation = nil
            departures = []
            selectedLine = nil
        }
        searchTask?.cancel()
        let text = stationQuery.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            stations = []
            pickerMessage = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let found = try await client.stations(matching: text)
                guard !Task.isCancelled else { return }
                stations = found
                pickerMessage = found.isEmpty ? .noStation : nil
            } catch {
                guard !Task.isCancelled else { return }
                pickerMessage = .failed
            }
        }
    }

    // MARK: - Estimates for trains followed online

    private var profilesEnabled: Bool { UserDefaults.standard.bool(forKey: "trackProfiles") }

    /// Speed and position from the section's speed profile, once loaded.
    func profileEstimate(_ status: TrainStatus) -> (speed: Int, position: Coordinate?)? {
        guard profilesEnabled, isOnline, let route = status.route, let estimate = status.routeEstimate(at: now),
              let profile = profiles[estimate.key]
        else { return nil }
        let state = profile.state(after: now.timeIntervalSince(estimate.departure))
        return (state.speed, route.coordinate(at: estimate.startDistance + state.distance))
    }

    /// Loads the profile for the section the train is on, if enabled. Called after each update.
    private func prepareProfile(for status: TrainStatus) {
        guard profilesEnabled, isOnline else {
            profileState = .off
            return
        }
        guard let route = status.route, let estimate = status.routeEstimate(at: Date()) else { return }
        if profiles[estimate.key] != nil { profileState = .ready } else { loadProfile(for: estimate, route: route) }
    }

    private func loadProfile(for estimate: RouteEstimate, route: Route) {
        guard !profileRequests.contains(estimate.key) else { return }
        if let failed = profileFailures[estimate.key], Date().timeIntervalSince(failed) < 300 { return }
        profileRequests.insert(estimate.key)
        profileState = .loading
        let points = route.points(from: estimate.startDistance, to: estimate.endDistance)
        let cacheKey = LimitCache.key(for: points)
        let overpass = overpass, cache = limitCache
        Task {
            // Matching tracks to the route is a bit of work, so keep it off the main thread.
            let limits: [Int]? = await Task.detached {
                if let cached = await cache.limits(for: cacheKey) { return cached }
                guard points.count >= 2, let tracks = try? await overpass.tracks(along: points), !tracks.isEmpty else { return nil }
                let samples = min(2000, max(2, Int(estimate.sectionLength / 100) + 1))
                let limits = SpeedProfile.limits(along: points, samples: samples, tracks: tracks)
                await cache.store(limits, for: cacheKey)
                return limits
            }.value
            profileRequests.remove(estimate.key)
            if let limits, let profile = SpeedProfile(length: estimate.sectionLength, limits: limits, duration: estimate.duration) {
                profiles[estimate.key] = profile
                profileState = .ready
            } else {
                profileFailures[estimate.key] = Date()
                profileState = .unavailable
            }
        }
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
        updatePlan { plan in
            plan.destinationStopID = destination.id
            plan.connection = connection
        }
    }

    func clearHistory() { history = TrainHistory() }
    func clearPlan() { plan = nil }

    private var strings: Strings {
        Strings(AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system)
    }

    // MARK: - Journey

    var destination: Stop? { status?.stops.first { $0.id == plan?.destinationStopID } }
    var boarding: Stop? { status?.stops.first { $0.id == plan?.boardingStopID } }

    func toggleDestination(_ stop: Stop) {
        updatePlan { plan in
            if plan.destinationStopID == stop.id {
                plan.destinationStopID = nil
                plan.connection = nil
            } else {
                plan.destinationStopID = stop.id
                if plan.connection?.station != stop.name { plan.connection = nil }
            }
        }
        isAddingConnection = false
    }

    func toggleBoarding(_ stop: Stop) {
        updatePlan { plan in plan.boardingStopID = plan.boardingStopID == stop.id ? nil : stop.id }
    }

    /// Connections the ICE portal lists for the destination; empty when not on an ICE.
    func loadPortalConnections() {
        portalConnections = []
        guard let portal = provider as? ICEPortal, let destination else { return }
        Task {
            let connections = (try? await portal.connections(at: destination)) ?? []
            portalConnections = connections.filter { ($0.departure ?? .distantFuture) >= (destination.arrival ?? now) }
        }
    }

    func chooseConnectionTarget(_ target: TransitousClient.Station) {
        guard let destination else { return }
        connectionSearch?.cancel()
        connectionTargets = []
        connectionTarget = target
        connectionQuery = target.name
        connectionMessage = .loadingDepartures
        let regional = UserDefaults.standard.bool(forKey: "regionalTrains")
        Task {
            do {
                guard let station = try await client.stations(matching: destination.name).first else {
                    connectionMessage = .noStation
                    return
                }
                let options = try await client.connections(
                    from: station, to: target, after: destination.arrival ?? now, regional: regional
                )
                connectionOptions = options.map { option in
                    var option = option
                    option.station = destination.name
                    return option
                }
                connectionMessage = options.isEmpty ? .noDepartures : nil
            } catch {
                connectionMessage = .failed
            }
        }
    }

    func chooseConnection(_ connection: Connection) {
        updatePlan { $0.connection = connection }
        isAddingConnection = false
    }

    func resetConnectionPicker() {
        connectionSearch?.cancel()
        connectionTargets = []
        connectionOptions = []
        connectionMessage = nil
        connectionTarget = nil
        connectionQuery = ""
    }

    private func connectionQueryChanged() {
        if let connectionTarget, connectionTarget.name == connectionQuery { return }
        connectionTarget = nil
        connectionSearch?.cancel()
        connectionOptions = []
        let text = connectionQuery.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            connectionTargets = []
            return
        }
        connectionSearch = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let found = try? await client.stations(matching: text), !Task.isCancelled else { return }
            connectionTargets = found
            connectionMessage = found.isEmpty ? .noStation : nil
        }
    }

    func removeConnection() {
        updatePlan { $0.connection = nil }
    }

    private func updatePlan(_ change: (inout JourneyPlan) -> Void) {
        guard let trainName = status?.trainName else { return }
        var updated = plan ?? JourneyPlan(trainName: trainName)
        change(&updated)
        let isEmpty = updated.boardingStopID == nil && updated.destinationStopID == nil && updated.connection == nil
        plan = isEmpty ? nil : updated
        if !isEmpty, notificationPermission != .allowed { requestNotificationPermission() }
        lastSnapshot = status.map { ($0, now, plan?.connection) }
    }

    private func notifyChanges(to newStatus: TrainStatus) {
        defer { lastSnapshot = (newStatus, Date(), plan?.connection) }
        guard let plan, let last = lastSnapshot, last.status.trainName == newStatus.trainName else { return }
        let events = JourneyWatcher.events(
            old: last.status, oldTime: last.time, oldConnection: last.connection,
            new: newStatus, newTime: Date(), newConnection: plan.connection, plan: plan,
            settings: notificationSettings
        )
        for event in events {
            var (title, body) = strings.notification(event)
            // The arrival reminder is the moment to think about the connection, so mention it.
            if case .arrivingSoon = event, let connection = plan.connection,
               let destination = newStatus.stops.first(where: { $0.id == plan.destinationStopID }) {
                body = [body, strings.connectionSummary(connection, arrival: destination.arrival)].compactMap { $0 }.joined(separator: " · ")
            }
            Notifier.post(title: title, body: body)
        }
    }

    /// Connections come from Transitous, so check them about once a minute.
    private func refreshConnectionIfNeeded() {
        guard let connection = plan?.connection,
              connectionRefreshed.map({ Date().timeIntervalSince($0) > 60 }) ?? true
        else { return }
        connectionRefreshed = Date()
        let portal = provider as? ICEPortal
        Task {
            var updated: Connection?
            // Prefer the ICE portal while on board: it works without internet access.
            if let portal, let stationID = connection.portalStationID, let stop = status?.stops.first(where: { $0.id == stationID }) {
                updated = try? await portal.connections(at: stop).first { $0.name == connection.name }
                updated?.finalStop = connection.finalStop
            }
            if updated == nil, connection.portalStationID == nil {
                updated = try? await client.refresh(connection)
            }
            guard let updated, plan?.connection?.tripID == updated.tripID else { return }
            plan?.connection = updated
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
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
                } else if !onBoardDismissed, let (found, first) = await Self.firstResponding(Providers.onBoard()) {
                    provider = found
                    apply(first)
                } else if let manualTarget {
                    await lookUp(manualTarget)
                }
            } else if let provider {
                do {
                    apply(try await provider.fetch())
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

    /// Portals are local and cheap; Transitous is a shared community service.
    private var pollInterval: Duration {
        if provider == nil { return .seconds(manualTarget == nil ? 15 : 60) }
        return isOnline ? .seconds(30) : .seconds(3)
    }

    private func lookUp(_ target: ManualTarget) async {
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
            switch error as? Transitous.LookupError {
            case .notRunning: lookupMessage = .notRunning(target.label)
            case .tripEnded: lookupMessage = .tripEnded
            case nil: lookupMessage = .unreachable
            }
        }
    }

    private func handle(_ error: Error) {
        failures += 1
        if error as? Transitous.LookupError == .tripEnded {
            lost()
            lookupMessage = .tripEnded
            // A picked trip won't run again; a train name might tomorrow.
            if case .trip = manualTarget { manualTarget = nil }
        } else if failures >= 4 {
            lost()
        }
    }

    private func apply(_ newStatus: TrainStatus) {
        guard !Task.isCancelled else { return }
        if let plan, plan.trainName != newStatus.trainName { self.plan = nil }
        notifyChanges(to: newStatus)
        refreshConnectionIfNeeded()
        status = newStatus
        lastUpdate = Date()
        prepareProfile(for: newStatus)
        failures = 0
        if newStatus.speed == nil { displaySpeed = nil }
    }

    private func lost() {
        provider = nil
        status = nil
        displaySpeed = nil
        topSpeed = 0
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
        if Int(date.timeIntervalSince1970) != Int(now.timeIntervalSince1970) { now = date }

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
