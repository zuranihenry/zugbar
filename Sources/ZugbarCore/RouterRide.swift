import Foundation

/// A ride on a train whose Wi-Fi router only has GPS (Icomera): the latest fix, the direction of travel, and the
/// train picked for it. Makes the decisions; the monitor does the polling and following.
public struct RouterRide: Sendable {
    /// A train picked from the GPS, not by the user.
    public struct Pick: Sendable, Equatable {
        public let tripID: String
        public let label: String

        public init(tripID: String, label: String) {
            self.tripID = tripID
            self.label = label
        }
    }

    public private(set) var fix: Icomera.Fix?
    private var fixReceived: Date?
    /// From the fixes themselves: the router's own course field can be stuck for minutes.
    public private(set) var heading: Double?
    private var headingFrom: Coordinate?
    /// Polls in a row the router didn't answer.
    public private(set) var failures = 0
    public private(set) var pick: Pick?
    /// With the router gone (Wi-Fi switched off or dropped while pulling in), the pick is still followed online
    /// until then, like a train whose ICE portal went away.
    public private(set) var pickUntil: Date?
    /// When following the pick online would end if the router went away now; from its last update.
    private var followDeadline: Date?
    /// The user stopped following the pick; holds until the next network or ride.
    public private(set) var dismissed = false
    /// Trips found not to be this train on this ride.
    public private(set) var rejected: Set<String> = []
    private var nextSearch: Date?
    private var searchDelay: TimeInterval = 15
    private var misses = 0
    private var lookupFailures = 0
    private var stops = StopCheck()

    public init() {}

    /// The router stopped answering, i.e. the user got off or left its Wi-Fi.
    public var isGone: Bool { failures >= 4 }

    /// The latest fix, while it's under 30 s old counting from when the router got it, not when it was fetched.
    public func freshFix(at now: Date) -> Icomera.Fix? {
        guard let fix, let fixReceived, fix.age + now.timeIntervalSince(fixReceived) < 30 else { return nil }
        return fix
    }

    /// Seconds until the next poll: quick while fixes come in and right after a missed one, slow once it's gone.
    public var pollDelay: TimeInterval { failures < 3 ? 3 : 30 }

    /// A fix from the router.
    public mutating func received(_ fix: Icomera.Fix, at now: Date) {
        self.fix = fix
        fixReceived = now
        failures = 0
        pickUntil = nil
        // Bearing between fixes at least 50 m apart, so jitter while standing doesn't turn the train around.
        if let from = headingFrom {
            if from.distance(to: fix.coordinate) >= 0.05 {
                heading = from.bearing(to: fix.coordinate)
                headingFrom = fix.coordinate
            }
        } else {
            headingFrom = fix.coordinate
        }
    }

    /// The router answered without a fix, e.g. in a tunnel: still on board.
    public mutating func answeredWithoutFix() { failures = 0 }

    /// The router didn't answer. After four times it's gone: a pick that has been followed carries on online
    /// until its last arrival, like a train whose ICE portal went away; one that never showed up is dropped.
    public mutating func unreachable() {
        failures += 1
        guard failures == 4 else { return }
        heading = nil
        headingFrom = nil
        misses = 0
        dismissed = false
        rejected = []
        resetSearch()
        if pick != nil {
            if let followDeadline { pickUntil = followDeadline } else { pick = nil }
        }
    }

    /// The pick updated online; `deadline` is when following it would end without the router.
    public mutating func followed(until deadline: Date) { followDeadline = deadline }

    /// Joining a network may mean another train: start over, but keep following the pick until it's shown wrong.
    public mutating func joinedNetwork() {
        let (pick, pickUntil) = (self.pick, self.pickUntil)
        self = RouterRide()
        self.pick = pick
        self.pickUntil = pickUntil
    }

    /// Whether to look for the train now: moving with a fresh fix, nothing picked, and not too soon after a miss.
    public func shouldSearch(at now: Date) -> Bool {
        guard pick == nil, !dismissed, heading != nil, let fix = freshFix(at: now), fix.speed >= 20 else { return false }
        return nextSearch.map { now >= $0 } ?? true
    }

    /// Backs off after a search that found nothing: 15 s, doubling up to 2 minutes.
    public mutating func searched(found: Bool, at now: Date) {
        if found { resetSearch(); return }
        nextSearch = now.addingTimeInterval(searchDelay)
        searchDelay = min(searchDelay * 2, 120)
    }

    public mutating func picked(_ pick: Pick) {
        self.pick = pick
        pickUntil = nil
        followDeadline = nil
        misses = 0
        lookupFailures = 0
        stops = StopCheck()
    }

    /// The pick to follow, if any: after the router went away, only until its deadline.
    public mutating func pickToFollow(at now: Date) -> Pick? {
        if let pickUntil, now >= pickUntil {
            pick = nil
            self.pickUntil = nil
        }
        return pick
    }

    /// Looking up the pick failed for a reason other than the network, e.g. its trip ended; after three in a row
    /// it's dropped and not picked again on this ride.
    public mutating func lookupFailed() {
        lookupFailures += 1
        if lookupFailures >= 3 { reject() }
    }

    public mutating func lookupSucceeded() { lookupFailures = 0 }

    /// The user stopped following the pick.
    public mutating func stopped() {
        pick = nil
        followDeadline = nil
        dismissed = true
    }

    /// Something else is followed now: the user's own pick, an on-board portal, or the connection.
    public mutating func superseded() {
        pick = nil
        followDeadline = nil
    }

    /// After each fix while following the pick or a train left behind: counts fresh, moving fixes that aren't on its
    /// line. True after about a minute of them, i.e. it's the wrong train.
    public mutating func isWrongTrain(gpsOnLine: Bool, at now: Date) -> Bool {
        guard let fix = freshFix(at: now), fix.speed >= 20 else { return false }
        misses = gpsOnLine ? 0 : misses + 1
        return misses >= 20
    }

    /// Records where the pick is along its route; true once it went through at least two of its stops without
    /// stopping, and more than it stopped at: a stopping train passing the odd request stop is still this one.
    public mutating func skipsStops(along: Double, stops alongs: [Double], at now: Date) -> Bool {
        guard let fix = freshFix(at: now), let fixReceived else { return false }
        let count = stops.record(along: along, speed: fix.speed, stops: alongs, at: fixReceived.addingTimeInterval(-fix.age))
        return count.skipped >= 2 && count.skipped > count.stopped
    }

    /// The pick isn't this train; it won't be picked again on this ride.
    public mutating func reject() {
        if let pick { rejected.insert(pick.tripID) }
        pick = nil
        pickUntil = nil
        followDeadline = nil
        misses = 0
        resetSearch()
    }

    private mutating func resetSearch() {
        nextSearch = nil
        searchDelay = 15
    }
}

/// Notices a train going through its own stops without stopping, i.e. the GPS belongs to another train on the
/// same line. Only judges stops it saw the train approach and leave: right after picking the train, or across a gap
/// in the fixes (sleep, no GPS under a station roof), a stop stays undecided.
public struct StopCheck: Sendable, Equatable {
    /// Lowest km/h seen within 500 m of each stop, by its meters along the route.
    private var slowest: [Double: Int] = [:]
    private var skipped: Set<Double> = []
    private var stopped: Set<Double> = []
    private var undecided: Set<Double> = []
    private var last: (along: Double, time: Date)?

    public init() {}

    public static func == (a: StopCheck, b: StopCheck) -> Bool {
        a.slowest == b.slowest && a.skipped == b.skipped && a.stopped == b.stopped && a.undecided == b.undecided
            && a.last?.along == b.last?.along && a.last?.time == b.last?.time
    }

    /// Records a fix taken at `time`. Returns the stops passed above 30 km/h and the ones stopped at so far.
    public mutating func record(along: Double, speed: Int, stops: [Double], at time: Date) -> (skipped: Int, stopped: Int) {
        // The same fix again, polled before the router had a new one.
        if let last, last.time == time { return (skipped.count, stopped.count) }
        if last == nil || time.timeIntervalSince(last!.time) > 10 {
            for stop in stops where abs(along - stop) <= 500 || last.map({ abs($0.along - stop) <= 500 }) == true {
                undecided.insert(stop)
            }
        }
        last = (along, time)
        for stop in stops where !undecided.contains(stop) {
            if abs(along - stop) <= 500 {
                slowest[stop] = min(slowest[stop] ?? speed, speed)
            } else if along > stop + 500, let lowest = slowest[stop], !skipped.contains(stop), !stopped.contains(stop) {
                if lowest > 30 { skipped.insert(stop) } else { stopped.insert(stop) }
            }
        }
        return (skipped.count, stopped.count)
    }
}

extension TrainStatus {
    /// Passed stops and the next stop from where the train is, `along` meters on `route`, e.g. from the router's
    /// GPS. Without live data the times say a late train already passed stops it hasn't reached yet, and an early one
    /// hasn't passed stops it has. A stop counts once the train is `margin` meters beyond it, so a train standing at
    /// the platform hasn't passed it. Stops without a coordinate go with their neighbors.
    public func passingStops(at along: Double, on route: Route, margin: Double = 400) -> TrainStatus {
        var status = self
        var decided: [Int: Bool] = [:]
        // In order: a station the train comes back to is placed on the way back.
        for (index, stop) in stopAlongs(on: route).enumerated() {
            guard let stop else { continue }
            decided[index] = along > stop + margin
        }
        for index in status.stops.indices {
            if let passed = decided[index] {
                status.stops[index].passed = passed
            } else if decided.contains(where: { $0.key > index && $0.value }) {
                status.stops[index].passed = true
            } else if decided.contains(where: { $0.key < index && !$0.value }) {
                status.stops[index].passed = false
            }
        }
        status.nextStopID = status.stops.first { !$0.passed && !$0.cancelled }?.id
        return status
    }
}
