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
    let wifi = WiFiForecaster()
    let link = LinkProber()
    let journey: Journey
    let trips = TripStore()
    private(set) var lastUpdate: Date?
    private(set) var lastError: String?
    private(set) var notificationPermission: Notifier.Permission?
    let updates = UpdateChecker()
    /// Set by "stop tracking" on board; cleared when the network changes.
    /// The on-board train the user stopped tracking: its portal is ignored for a while, other trains' aren't.
    @ObservationIgnored private var dismissedTrain: (name: String, at: Date)?

    private(set) var displaySpeed: Int?
    private(set) var topSpeed = 0
    private(set) var now = Date()
    private(set) var lookupMessage: LookupMessage?

    var demoMode = false {
        didSet {
            guard demoMode != oldValue else { return }
            // The demo train would replace the real plan; it comes back, and the demo state goes, when demo mode ends.
            if demoMode {
                stashedPlan = journey.plan
            } else {
                lost()
                journey.plan = stashedPlan
                journey.lastSnapshot = nil
                stashedPlan = nil
            }
            restart()
        }
    }
    @ObservationIgnored private var stashedPlan: JourneyPlan?

    /// Followed online when no on-board portal answers. On-board data always takes precedence.
    var manualTarget: ManualTarget? = TrainMonitor.loadTarget() {
        didSet {
            guard manualTarget != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(manualTarget), forKey: "manualTarget")
            if manualTarget != nil { ride.superseded() }
            lookupOutages = 0
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
    /// Lookups of the shown train that failed for lack of network since it last updated. Train Wi-Fi drops in and
    /// out, and every drop restarts the poll loop: the train stays up meanwhile instead of the panel going blank.
    @ObservationIgnored private var lookupOutages = 0
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var routerGPSTask: Task<Void, Never>?
    /// On a train whose router only has GPS (Icomera): its fixes, and the train picked from them.
    @ObservationIgnored private var ride = RouterRide()
    /// Found which SBB train the user is on since joining this network, or that there's nothing to switch to.
    @ObservationIgnored private var sbbSettled = false
    @ObservationIgnored private var sbbTried: Date?
    @ObservationIgnored private var networkJoined = Date()
    /// The DHCP domains when last joining a network: path updates also come from VPNs and lease renewals.
    @ObservationIgnored private var networkDomains: [String] = []
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
            planSet: { box.value?.askForNotifications() }, loadsCoaches: { box.value?.demoMode == false }
        )
        box.value = self
    }

    convenience init() {
        self.init(snapshot: nil, history: nil, demo: CommandLine.arguments.contains("--demo"))
        estimates.loadLearnedSpeeds()
        wifi.load()
        startTicking()
        startFrames()
        startRouterGPS()
        restart()
        // Boarding means joining a new network; look for a portal right away.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.demoMode else { return }
                let domains = OnboardNetwork.dhcpDomains
                if domains != self.networkDomains {
                    self.networkDomains = domains
                    self.networkJoined = Date()
                    self.sbbSettled = false
                    self.sbbTried = nil
                    self.ride.joinedNetwork()
                }
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
        guard let status else { return nil }
        if demoMode { return .demo }
        // Between a dropped connection and the next update there's no provider; the status still says where it came from.
        return status.isOnline ? .online : .onBoard
    }

    /// Stops whatever is being shown: online following, demo mode, or (until the network changes) the on-board train.
    func endTracking() {
        switch tracking {
        case .demo: demoMode = false
        case .online: stopTracking()
        case .onBoard:
            dismissedTrain = status?.trainName.map { ($0, Date()) }
            trips.finish()
            onBoardTrain = nil
            lost()
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

    /// A plan was set: notifications are what it's for. Asks the system once; opening System Settings after a
    /// "no" is left to the buttons that say so.
    private func askForNotifications() {
        guard Notifier.isEnabled, notificationPermission == nil || notificationPermission == .notAsked else { return }
        Task {
            _ = await Notifier.requestPermission()
            notificationPermission = await Notifier.permission()
        }
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

    /// Reload: also brings back an on-board train the user stopped tracking.
    func refresh() {
        dismissedTrain = nil
        restart()
    }

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
        lookupOutages = 0
        onBoardTrain = nil
        if manualTarget == nil, status?.isOnline == true, ride.pick != nil { ride.stopped() }
        // Following the on-board train online has no target to clear, so restart explicitly.
        if manualTarget == nil { restart() } else { manualTarget = nil }
    }

    // MARK: - Map position

    /// Moves the marker on from GPS fixes: along the route at the reported speed, else gliding from fix to fix.
    @ObservationIgnored private var marker = GPSMarker()
    /// Holds the last good fix while a stale one lies behind the train.
    @ObservationIgnored private var gpsFilter = GPSFilter()
    /// Where the router's GPS last put the followed train along its route, for moments without a fix.
    @ObservationIgnored private var routerAlong: (train: String, along: Double)?
    private var frameTask: Task<Void, Never>?

    /// Maps on screen; the marker only needs smooth frames while one is.
    @ObservationIgnored var mapsShown = 0

    /// Recomputes the marker about 30 times a second from the clock, so it moves at a constant pace, while a map
    /// shows it; once a second otherwise, so the heading stays fresh for when one opens.
    private func startFrames() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.moveTrain()
                let smooth = (self?.mapsShown ?? 0) > 0 && self?.status != nil
                try? await Task.sleep(for: smooth ? .milliseconds(33) : .seconds(1))
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
            marker.update(gps, speed: status.speed, route: status.route, nextStop: status.nextStop?.coordinate, at: date)
            trainPosition = marker.position(at: date)
        } else if holdsMarker(for: status, at: date), let held = marker.position(at: date) {
            // In a tunnel the router's GPS goes quiet: the marker goes on from its last fix as between fixes, instead of
            // jumping to where the times say and back.
            trainPosition = held
        } else {
            // Back on GPS later, the marker starts from the new fix instead of gliding from an old one.
            marker = GPSMarker()
            trainPosition = estimates.position(of: status, at: date)
        }
        if let trainPosition { map.trainMoved(to: trainPosition, at: date) }
    }

    /// Where the marker will be at `date`, for camera animations that should end on the moving train.
    func predictedPosition(at date: Date) -> Coordinate? {
        guard let status else { return nil }
        guard status.position != nil else {
            if holdsMarker(for: status, at: date), let held = marker.position(at: date) { return held }
            return estimates.position(of: status, at: date)
        }
        return marker.position(at: date) ?? status.position
    }

    /// A train followed online whose router GPS last had it on its line, and still answers with a recent fix.
    private func holdsMarker(for status: TrainStatus, at date: Date) -> Bool {
        guard status.isOnline, let last = routerAlong, TrainName.same(last.train, status.trainName ?? "") else { return false }
        return ride.holdsPosition(at: date)
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
            if !sbbSettled, !demoMode, sbbTried.map({ Date().timeIntervalSince($0) > 120 }) ?? true,
               journey.plan?.isRecent(at: Date()) == true, OnboardNetwork.dhcpDomains.contains(where: SBB.isTrainWiFi) {
                sbbTried = Date()
                switch await followSBBTrain() {
                case .switched: sbbSettled = true; return
                case .settled: sbbSettled = true
                case .retry: break
                }
            }
            if provider == nil {
                if demoMode {
                    provider = DemoProvider()
                    continue
                } else if await takeOverFromPortal() {
                    // On-board data takes precedence.
                } else if Task.isCancelled {
                    return
                } else if status?.isOnline == false,
                          Handover.isDue(plan: journey.plan, status: status, now: Date(), leeway: Self.arrivalLeeway) {
                    // The train's Wi-Fi went away as it arrived at the destination: the user is changing trains.
                    followConnection()
                } else if let manualTarget {
                    await lookUp(manualTarget)
                } else if let train = fallbackTrain {
                    portalProbed = Date()
                    await lookUp(.name(train), fallback: true)
                } else if let pick = ride.pickToFollow(at: Date()) {
                    // Picked from the router's GPS earlier: back after Reload, a network change or a failed update.
                    await lookUp(pick)
                } else if ride.shouldSearch(at: Date()) {
                    await followRouterTrain()
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

            // A restart cancelled this loop while it waited; the new loop takes it from here.
            if Task.isCancelled { return }
            if provider == nil, status != nil, !staysUp(after: lookupOutages) { lost() }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Switches to an on-board portal if one answers, other than the train the user changed from.
    private func takeOverFromPortal() async -> Bool {
        guard let (found, first) = await Self.firstResponding(Providers.onBoard(loader: PortalRecorder.wrap(URLSession.portal.loader))),
              !Task.isCancelled, !isLeftBehind(first)
        else { return false }
        provider = found
        ride.superseded()
        // The portal leads from now on. A search from before boarding, or the train itself followed while waiting for
        // it, shouldn't come back once this train's Wi-Fi is gone: it's then followed online only to the destination.
        if manualTarget != nil, first.trainName != nil {
            quietlySetTarget(nil)
        }
        apply(first)
        return true
    }

    /// The on-board train to follow online while its portal doesn't answer, e.g. after the Wi-Fi dropped.
    private var fallbackTrain: String? {
        guard let onBoardTrain, Date() < onBoardTrain.until else { return nil }
        return onBoardTrain.name
    }

    /// Portals are local and cheap; Transitous is a shared community service.
    private var pollInterval: Duration {
        if provider == nil {
            // A train followed online is looked up once a minute, and through a dead zone at the pace of its updates.
            guard manualTarget != nil || fallbackTrain != nil else { return .seconds(15) }
            return .seconds(lookupOutages > 0 ? 30 : 60)
        }
        return isOnline ? .seconds(30) : .seconds(3)
    }

    /// Whether the shown train stays up after `outages` updates failed for lack of network. One the user chose is
    /// kept to its last stop; the on-board train, or one picked from the router's GPS, only to the destination.
    private func staysUp(after outages: Int) -> Bool {
        Handover.staysUp(status, outages: outages, plan: manualTarget == nil ? journey.plan : nil, now: Date())
    }

    /// `fallback`: following the on-board train whose portal went away; a failed search ends that quietly.
    @discardableResult
    private func lookUp(_ target: ManualTarget, fallback: Bool = false) async -> Error? {
        let online = switch target {
        case .name(let name): Transitous(query: name)
        case .trip(let id, let label): Transitous(tripID: id, label: label)
        }
        lookupMessage = .lookingUp(target.label)
        do {
            let first = try await online.fetch()
            guard !Task.isCancelled else { return nil }
            provider = online
            lookupMessage = nil
            lookupOutages = 0
            apply(first)
            return nil
        } catch {
            guard !Task.isCancelled else { return error }
            if error.isTransientNetwork, let name = status?.trainName, TrainName.same(target.label, name) {
                lookupOutages += 1
                lastError = String(describing: error)
            }
            if fallback, let error = error as? Transitous.LookupError {
                onBoardTrain = nil
                lookupMessage = nil
                if error == .tripEnded, Handover.isDueAfterTripEnded(plan: journey.plan, trainName: target.label, now: Date()) {
                    followConnection()
                }
                return error
            }
            switch error as? Transitous.LookupError {
            case .notRunning: lookupMessage = .notRunning(target.label)
            case .tripEnded:
                if Handover.isDueAfterTripEnded(plan: journey.plan, trainName: target.label, now: Date()) {
                    followConnection()
                    return error
                }
                // A picked trip won't run again, so don't keep asking for it after a relaunch.
                if case .trip = target { quietlySetTarget(nil) }
                lookupMessage = .tripEnded
            case nil:
                if case .trip = target, case ProviderError.badStatus(404) = error {
                    quietlySetTarget(nil)
                    lookupMessage = .tripEnded
                } else {
                    lookupMessage = .unreachable
                }
            }
            return error
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
            if case .trip = manualTarget { quietlySetTarget(nil) }
        } else if (isOnline && error.isTransientNetwork) ? !staysUp(after: failures) : failures >= 4 {
            if status?.isOnline == false, Handover.isDue(plan: journey.plan, status: status, now: Date(), leeway: Self.arrivalLeeway) {
                return followConnection()
            }
            // A portal that stops answering mid-trip is like a dropped Wi-Fi: the train stays up, and is looked for
            // again right away, on its portal and else online.
            if !isOnline, !demoMode, fallbackTrain != nil { return restart() }
            lost()
        }
    }

    /// Train Wi-Fi often drops while pulling into a station, a little before the timetabled arrival.
    private static let arrivalLeeway: TimeInterval = 3 * 60

    /// Switches to the planned connection after the user changed trains at the destination.
    private func followConnection() {
        guard !demoMode, !findingReplacement, let plan = journey.plan, let connection = plan.connection else { return }
        let arrival = status?.stops.first { $0.id == plan.destinationStopID }?.arrival
        if Handover.needsReplacement(connection, arrival: arrival) {
            // The connection is cancelled, or left before the train got in: take the next train to the same place
            // instead. Searched once per connection, again only after a network error.
            if let search = replacementSearch, search.tripID == connection.tripID,
               !(search.networkError && Date().timeIntervalSince(search.at) > 120) {
                return
            }
            findingReplacement = true
            let title = connection.cancelled ? strings.connectionCancelled : strings.connectionMissed
            Task {
                let (next, networkError) = await replacement(for: connection, after: arrival ?? Date())
                replacementSearch = (connection.tripID, Date(), networkError)
                findingReplacement = false
                if let next {
                    Notifier.post(title: title, body: strings.nextTrain(next))
                    journey.plan?.connection = next
                    followConnection()
                } else if !networkError {
                    Notifier.post(title: title, body: strings.noNextTrain)
                }
            }
            return
        }
        leftTrain = (plan.trainName, Date())
        onBoardTrain = nil
        replacementSearch = nil
        journey.plan = Handover.plan(after: connection)
        journey.lastSnapshot = nil
        let target = Handover.target(for: connection)
        quietlySetTarget(ManualTarget(target))
        lost()
        restart()
        if case .name = target { findTrip(of: connection) }
    }

    @ObservationIgnored private var findingReplacement = false
    @ObservationIgnored private var replacementSearch: (tripID: String, at: Date, networkError: Bool)?

    /// The earliest direct train after `connection` from the same station to the same final stop.
    /// The next direct train between the connection's stops, and whether the search failed for lack of network.
    private func replacement(for connection: Connection, after earliest: Date) async -> (next: Connection?, networkError: Bool) {
        guard let final = connection.finalStop else { return (nil, false) }
        do {
            guard let from = try await client.stations(matching: connection.station).first,
                  let to = try await client.stations(matching: final).first
            else { return (nil, false) }
            let options = try await client.connections(from: from, to: to, after: earliest, regional: true)
            guard var next = Handover.replacement(for: connection, in: options, after: earliest) else { return (nil, false) }
            next.station = connection.station
            return (next, false)
        } catch {
            return (nil, error.isTransientNetwork)
        }
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
            guard let next = await replacement(for: leg, after: (leg.departure ?? Date()).addingTimeInterval(60)).next else {
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

    /// The train the user changed from, or stopped tracking, within the last three hours.
    private func isLeftBehind(_ status: TrainStatus) -> Bool {
        guard let name = status.trainName else { return false }
        return [leftTrain, dismissedTrain].contains { train in
            guard let train, Date().timeIntervalSince(train.at) < 3 * 60 * 60 else { return false }
            return TrainName.same(train.name, name)
        }
    }

    /// Changes the target from within the poll loop, without restarting it.
    private func quietlySetTarget(_ target: ManualTarget?) {
        restartsOnTargetChange = false
        manualTarget = target
        restartsOnTargetChange = true
    }

    private func apply(_ newStatus: TrainStatus) {
        guard !Task.isCancelled else { return }
        lookupOutages = 0
        // The new train's section right away, not up to a second later.
        estimates.refreshSection(for: newStatus, at: Date())
        var newStatus = withRouterGPS(newStatus)
        let anotherTrain = status?.trainName.flatMap { old in newStatus.trainName.map { !TrainName.same(old, $0) } } ?? false
        if anotherTrain { gpsFilter = GPSFilter() }
        if !newStatus.isOnline, let position = newStatus.position {
            // Before the marker, the trip and learned speeds see it: at speed the ICE portal sometimes sends a fix
            // from a minute ago again.
            newStatus.position = gpsFilter.filter(position, speed: newStatus.speed, at: Date())
        }
        if manualTarget == nil, let pick = ride.pick, newStatus.isOnline, TrainName.same(pick.label, newStatus.trainName ?? "") {
            ride.followed(until: Handover.fallbackDeadline(for: newStatus, plan: journey.plan, now: Date()))
        }
        if newStatus.route == nil, !isOnline, !demoMode, let name = newStatus.trainName {
            if let route = onBoardRoutes[name] { newStatus.route = route } else { loadOnBoardRoute(for: name) }
        }
        if let plan = journey.plan, let connection = Handover.boardedConnection(plan: plan, trainName: newStatus.trainName, now: Date()) {
            // On the connection already, e.g. woken on it: hand over instead of dropping the plan as another train's.
            leftTrain = (plan.trainName, Date())
            onBoardTrain = nil
            journey.plan = Handover.plan(after: connection)
            journey.lastSnapshot = nil
        }
        journey.follow(newStatus, previous: status)
        if !newStatus.isOnline, !demoMode, let name = newStatus.trainName {
            onBoardTrain = (name, Handover.fallbackDeadline(for: newStatus, plan: journey.plan, now: Date()))
        }
        journey.notifyChanges(to: newStatus, strings: strings)
        if anotherTrain {
            // Another train: its own top speed, and its marker doesn't glide from where the last one was.
            topSpeed = 0
            displaySpeed = nil
            marker = GPSMarker()
        }
        journey.refreshConnectionIfNeeded()
        if !demoMode {
            if !newStatus.isOnline {
                newStatus.internet = Internet.combining(portal: newStatus.internet, measured: link.current(at: Date()))
            }
            newStatus = wifi.update(newStatus, strings: strings)
        }
        status = newStatus
        lastUpdate = Date()
        journey.refreshCoaches()
        estimates.prepareProfile(for: newStatus)
        if !demoMode {
            estimates.learn(from: newStatus)
            trips.record(newStatus)
        }
        failures = 0
        if newStatus.speed == nil { displaySpeed = nil }
        if Handover.isDue(plan: journey.plan, status: newStatus, now: Date()), !stillAboard(newStatus) {
            followConnection()
        } else if newStatus.isOnline, manualTarget == nil, let train = onBoardTrain?.name ?? (followsPick ? ride.pick?.label : nil),
                  TrainName.same(train, newStatus.trainName ?? ""),
                  Handover.hasReached(plan: journey.plan, status: newStatus, now: Date(), grace: 15 * 60), !stillAboard(newStatus) {
            // The on-board train followed online, or the one picked from the router's GPS, got the user to their
            // destination; it isn't followed on to its last stop.
            onBoardTrain = nil
            ride.superseded()
            lost()
        }
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

    /// Signs the user is still on the train followed online, when the timetable says it has arrived: its router's GPS
    /// isn't at the destination yet, or an SBB train's Wi-Fi is still there. Leaving the Wi-Fi is the moment to change.
    /// On board, the portal still shows the train on its way in.
    private func stillAboard(_ status: TrainStatus) -> Bool {
        if Handover.isStillApproaching(plan: journey.plan, status: status) { return true }
        guard status.isOnline, let plan = journey.plan,
              let destination = status.stops.first(where: { $0.id == plan.destinationStopID })
        else { return false }
        if let position = status.position, let coordinate = destination.coordinate {
            return position.distance(to: coordinate) > 1
        }
        return OnboardNetwork.dhcpDomains.contains(where: SBB.isTrainWiFi)
    }

    // MARK: - SBB trains

    enum SBBCheck { case switched, settled, retry }

    /// On an SBB train's Wi-Fi with a plan for another train, the user got on a different train than planned:
    /// follows the SBB train that left their boarding stop for their destination, and moves the plan over.
    /// `retry` when a request failed or the train hasn't left yet.
    private func followSBBTrain() async -> SBBCheck {
        guard let plan = journey.plan else { return .settled }
        guard let (boarding, destination) = await stopNames(of: plan) else { return .retry }
        var anchor = SBB.transitousStopID(plan.boardingStopID)
        if anchor == nil { anchor = try? await client.stations(matching: boarding).first?.id }
        let now = Date()
        guard let anchor,
              let departures = try? await client.longDistanceDepartures(near: anchor, before: now.addingTimeInterval(15 * 60), count: 40)
        else { return .retry }
        for departure in SBB.candidates(departures, now: now, joined: networkJoined).prefix(6) {
            guard let trip = try? await Transitous(tripID: departure.tripID, label: departure.displayName).fetch() else {
                if Task.isCancelled { return .retry }
                continue
            }
            guard SBB.serves(trip, from: boarding, to: destination) else { continue }
            // Already on it, e.g. after a relaunch: the plan moved over earlier.
            if TrainName.same(plan.trainName, departure.displayName) { return .settled }
            if let name = status?.trainName, TrainName.same(name, departure.displayName) { return .settled }
            // Boarded early: switch once it has left, in case the user gets off again.
            if let time = departure.time, time > Date() { return .retry }
            guard !Task.isCancelled else { return .retry }
            Notifier.post(title: strings.onOtherTrain(departure.displayName),
                          body: strings.planMoved(from: plan.trainName, to: StationName.tidy(destination)))
            journey.plan = SBB.plan(plan, on: departure.displayName, from: boarding, to: destination)
            journey.lastSnapshot = nil
            let label = [departure.displayName, departure.headsign.map { "→ \($0)" }].compactMap { $0 }.joined(separator: " ")
            quietlySetTarget(.trip(id: departure.tripID, label: label))
            restart()
            return .switched
        }
        return .settled
    }

    /// The plan's boarding stop and destination by name, from the followed train or else the planned one.
    private func stopNames(of plan: JourneyPlan) async -> (String, String)? {
        func names(in status: TrainStatus?) -> (String, String)? {
            let boarding = status?.stops.first { $0.id == plan.boardingStopID }?.name ?? plan.pendingBoarding
            let destination = status?.stops.first { $0.id == plan.destinationStopID }?.name ?? plan.pendingDestination
            guard let boarding, let destination else { return nil }
            return (boarding, destination)
        }
        if let found = names(in: status) { return found }
        return names(in: try? await Transitous(query: plan.trainName).fetch())
    }

    // MARK: - Router GPS

    /// Polls the train router's GPS while nothing or a train online is followed: on DB Regio and other trains with
    /// Icomera Wi-Fi, that's the real position and speed instead of an estimate, and tells which train it is.
    private func startRouterGPS() {
        routerGPSTask = Task { [weak self] in
            let router = Icomera()
            while !Task.isCancelled {
                guard let self, !demoMode, status?.isOnline ?? true else {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                do {
                    ride.received(try await router.fetch(), at: Date())
                } catch ProviderError.missingResource("GPS fix") {
                    ride.answeredWithoutFix()
                } catch {
                    ride.unreachable()
                }
                checkRouterTrain()
                try? await Task.sleep(for: .seconds(ride.pollDelay))
            }
        }
    }

    /// The followed train is the one picked from the router's GPS.
    private var followsPick: Bool { ride.pick != nil && manualTarget == nil && isOnline }

    /// After each poll: puts the GPS on the followed train, and drops the pick, or a train left behind, once the
    /// GPS shows the user is on another one.
    private func checkRouterTrain() {
        guard let status, status.isOnline else { return }
        let updated = withRouterGPS(status)
        if updated != status {
            self.status = updated
            if updated.speed == nil { displaySpeed = nil }
        }
        guard manualTarget == nil, isOnline, followsPick || fallbackTrain != nil else { return }
        let now = Date()
        var wrong = ride.isWrongTrain(gpsOnLine: updated.position != nil, at: now)
        // A train that runs through its own stops isn't this one; unless the user planned their trip on it.
        if followsPick, !wrong, updated.position != nil, let route = status.route, let fix = ride.freshFix(at: now),
           journey.plan.map({ TrainName.same($0.trainName, status.trainName ?? "") }) != true {
            let stops = status.stops.filter { !$0.cancelled }.compactMap(\.coordinate).map { route.projection(of: $0).along }
            wrong = ride.skipsStops(along: route.projection(of: fix.coordinate, heading: ride.heading).along, stops: stops, at: now)
        }
        guard wrong else { return }
        if followsPick { ride.reject() } else { onBoardTrain = nil }
        lost()
        restart()
    }

    /// On a train whose Wi-Fi only has GPS, follows the train running there. Needs the train moving: at a station,
    /// the GPS can't tell the trains standing there apart.
    private func followRouterTrain() async {
        guard let fix = ride.freshFix(at: Date()), let heading = ride.heading,
              manualTarget == nil, status == nil, provider == nil
        else { return }
        let train = try? await client.train(at: fix, heading: heading, excluding: ride.rejected)
        ride.searched(found: train != nil, at: Date())
        guard let train, !Task.isCancelled, manualTarget == nil, status == nil, provider == nil else { return }
        // Not a manual target: that would be remembered after leaving the train and keep a portal from taking over.
        let pick = RouterRide.Pick(tripID: train.tripID, label: train.name)
        ride.picked(pick)
        await lookUp(pick)
    }

    private func lookUp(_ pick: RouterRide.Pick) async {
        let error = await lookUp(.trip(id: pick.tripID, label: pick.label), fallback: true)
        guard !Task.isCancelled else { return }
        if provider == nil {
            // Not a train the user asked for, so no "unreachable" for it. A network outage, a busy or broken server
            // say nothing about the train; only other failures, like its trip having ended, count against it.
            lookupMessage = nil
            if error?.isTransientNetwork == true { return }
            ride.lookupFailed()
        } else if ride.pick != pick {
            // Dropped while being looked up, e.g. the router went away meanwhile.
            provider = nil
            lost()
        } else {
            ride.lookupSucceeded()
        }
    }

    /// The router's position and speed on a train followed online, if the fix is fresh and on that train's line.
    private func withRouterGPS(_ status: TrainStatus) -> TrainStatus {
        guard status.isOnline else { return status }
        var status = status
        status.position = nil
        status.speed = nil
        guard let fix = ride.freshFix(at: Date()), isOnTrack(fix, of: status) else {
            // A moment without a fix, in a tunnel or under a station roof, doesn't put the train back where the times
            // say: it's still about where the GPS last had it.
            if !ride.isGone, let last = routerAlong, TrainName.same(last.train, status.trainName ?? ""), let route = status.route {
                return status.passingStops(at: last.along, on: route)
            }
            return status
        }
        status.position = fix.coordinate
        status.speed = fix.speed
        // The router knows where the train is; without live data the times only say where it should be. Not while
        // waiting for this train at the boarding stop: the GPS is then from the train the user is on or just left.
        let boarding = journey.plan?.resolved(in: status).boardingStopID
        if let route = status.route, route.points.count > 1, let name = status.trainName,
           followsPick || status.waitingStop(boarding, at: Date()) == nil {
            // The smoothed heading even when slow, so a train standing on its way back stays on that leg.
            let along = route.projection(of: fix.coordinate, heading: ride.heading).along
            routerAlong = (name, along)
            status = status.passingStops(at: along, on: route)
        }
        return status
    }

    /// Whether a router fix belongs to this train: on its line, going its way, and unless the GPS picked it, near
    /// where the live times put it. Following another train from inside one with router Wi-Fi mustn't move it.
    private func isOnTrack(_ fix: Icomera.Fix, of status: TrainStatus) -> Bool {
        let picked = manualTarget == nil && ride.pick != nil
        guard let route = status.route, route.points.count > 1 else {
            guard let estimate = estimates.position(of: status, at: Date()) else { return false }
            return fix.coordinate.distance(to: estimate) < (picked ? 30 : 5)
        }
        let position = route.projection(of: fix.coordinate, heading: fix.speed >= 20 ? ride.heading : nil)
        // Long pieces are straight lines between stops where the feed has no shape.
        guard position.offset < (position.pieceLength > 2_000 ? 1.5 : 0.5) else { return false }
        if fix.speed >= 20, let heading = ride.heading, let bearing = route.bearing(at: position.along),
           abs((bearing - heading + 540).truncatingRemainder(dividingBy: 360) - 180) >= 90 {
            return false
        }
        // The live times can be well off: for the train picked from the GPS, about as far off as the search allows.
        guard let estimate = estimates.position(of: status, at: Date()) else { return picked }
        return abs(position.along - route.projection(of: estimate).along) < (picked ? 30_000 : 15_000)
    }

    private func lost() {
        lookupOutages = 0
        provider = nil
        status = nil
        trainPosition = nil
        displaySpeed = nil
        topSpeed = 0
        // The next train's first fix shouldn't glide from where this one was.
        marker = GPSMarker()
        gpsFilter = GPSFilter()
        routerAlong = nil
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
            trips.finishIfIdle()
            // Picks up the setting being switched on and the train entering a new section without waiting for the next poll.
            if let status { estimates.prepareProfile(for: status) }
            estimates.refreshSection(for: status, at: now)
            updateLink()
        }

        // An on-board train whose portal stopped answering, e.g. after the Wi-Fi went away or a sleep: its last
        // speed and GPS fix aren't live any more. Online, router GPS updates them between polls.
        if var kept = status, !kept.isOnline, kept.speed != nil || kept.position != nil,
           let last = lastUpdate, date.timeIntervalSince(last) > 90 {
            kept.speed = nil
            kept.position = nil
            status = kept
            displaySpeed = nil
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

extension TrainMonitor {
    /// Measures the Wi-Fi on board, where a portal answers; not while following a train online, where the Mac is
    /// often on a regional train's Wi-Fi with a data limit, or on a phone's hotspot.
    fileprivate func updateLink() {
        let onBoard = status.map { !$0.isOnline } == true && !demoMode && !isSnapshot
        link.run(onBoard)
        // With the portal silent, e.g. its own server down, only the measurement still knows.
        guard onBoard, var kept = status, let last = lastUpdate, now.timeIntervalSince(last) > 10,
              let reading = link.current(at: now), kept.internet?.current != reading.quality
        else { return }
        kept.internet = Internet(current: reading.quality)
        status = kept
    }
}

/// Lets the parts reach the monitor without keeping it alive.
private final class WeakBox<T: AnyObject> {
    weak var value: T?
}
