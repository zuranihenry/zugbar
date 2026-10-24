import Foundation

/// How good the train Wi-Fi was where, learned on board. Stored per grid cell (the same ~280 m cells as the learned
/// speeds) as how many rides found it good, weak or offline there; no trips, times or tracks, so it stays anonymous.
public struct LearnedWiFi: Codable, Sendable, Equatable {
    struct Cell: Codable, Sendable, Equatable {
        var good = 0
        var weak = 0
        var none = 0

        var total: Int { good + weak + none }

        /// What most rides found, erring on the bad side: weak or offline once that's at least half of them.
        var quality: Internet.Quality? {
            guard total > 0 else { return nil }
            guard (weak + none) * 2 >= total else { return .good }
            return none >= weak ? Internet.Quality.none : .weak
        }
    }

    /// Rides a cell remembers in full; beyond that older ones count half, so new masts and repeaters show.
    static let memory = 12
    /// Spacing of the samples along the track ahead.
    static let step = 100.0
    /// Shorter stretches pass in seconds and aren't worth a forecast.
    static let shortest = 500.0
    /// Longest gap without data bridged between weak or offline sides: tunnels, where there's no GPS.
    static let tunnel = 15_000.0
    /// Longest gap without data bridged between sides that agree, e.g. a cell the train crossed between two polls.
    static let gap = 1_000.0
    /// How far ahead forecasts look, at most.
    static let horizon = 60_000.0

    private var cells: [String: Cell] = [:]

    public init() {}

    public var cellCount: Int { cells.count }

    /// One ride's verdict on the cell around `coordinate`.
    public mutating func record(_ quality: Internet.Quality, at coordinate: Coordinate) {
        let key = Self.key(LearnedSpeeds.index(coordinate))
        var cell = cells[key] ?? Cell()
        switch quality {
        case .good: cell.good += 1
        case .weak: cell.weak += 1
        case .none: cell.none += 1
        }
        if cell.total > Self.memory {
            cell = Cell(good: (cell.good + 1) / 2, weak: (cell.weak + 1) / 2, none: (cell.none + 1) / 2)
        }
        cells[key] = cell
    }

    /// What earlier rides found around `coordinate`: in its own cell, or else in the eight around it, since the
    /// route's line runs a little beside the GPS fixes in places.
    public func quality(at coordinate: Coordinate) -> Internet.Quality? {
        let (lat, lon) = LearnedSpeeds.index(coordinate)
        if let own = cells[Self.key((lat, lon))] { return own.quality }
        var around = Cell()
        for dLat in -1...1 {
            for dLon in -1...1 {
                guard let cell = cells[Self.key((lat + dLat, lon + dLon))] else { continue }
                around.good += cell.good
                around.weak += cell.weak
                around.none += cell.none
            }
        }
        return around.quality
    }

    /// The Wi-Fi earlier rides found on the track ahead of the train: up to its next stop, where the train stands
    /// for a while and times from its speed stop working, and at most `horizon`. `along` is where the train is on
    /// its route, in meters.
    public func forecast(for status: TrainStatus, along: Double, at date: Date) -> WiFiForecast? {
        guard let route = status.route, let speed = status.speed else { return nil }
        var end = min(route.length, along + Self.horizon)
        if let stop = status.nextStop?.coordinate { end = min(end, route.distance(of: stop, from: along)) }
        return forecast(along: route, from: along, to: end, speed: speed, at: date)
    }

    /// The Wi-Fi earlier rides found along `route` between two distances, for a train at `start` going `speed` km/h.
    /// `nil` when slower than 30 km/h, where times from the speed mean little, or when nothing ahead is known.
    public func forecast(along route: Route, from start: Double, to end: Double, speed: Int, at date: Date) -> WiFiForecast? {
        guard speed >= 30, end > start else { return nil }
        let samples = (0...Int((end - start) / Self.step)).map { index in
            route.coordinate(at: start + Double(index) * Self.step).flatMap(quality(at:))
        }
        let stretches = Self.stretches(from: samples)
        guard !stretches.isEmpty else { return nil }
        return WiFiForecast(stretches: stretches, speed: Double(speed) / 3.6, date: date)
    }

    /// Evenly spaced samples as stretches of the same Wi-Fi, smoothed: gaps without data in tunnels and between
    /// agreeing sides filled in, short dips merged into what's around them, other short bits left out.
    static func stretches(from samples: [Internet.Quality?]) -> [WiFiForecast.Stretch] {
        typealias Run = (quality: Internet.Quality?, start: Int, end: Int)
        func merged(_ runs: [Run]) -> [Run] {
            runs.reduce(into: []) { result, run in
                if let last = result.last, last.quality == run.quality { result[result.count - 1].end = run.end } else { result.append(run) }
            }
        }
        func length(_ run: Run) -> Double { Double(run.end - run.start) * step }

        var runs = merged(samples.enumerated().map { ($1, $0, $0 + 1) })
        for index in runs.indices.dropFirst().dropLast() where runs[index].quality == nil {
            guard let before = runs[index - 1].quality, let after = runs[index + 1].quality else { continue }
            if before == after, length(runs[index]) <= gap {
                runs[index].quality = before
            } else if before != .good, after != .good, length(runs[index]) <= tunnel {
                runs[index].quality = before.severity >= after.severity ? before : after
            }
        }
        runs = merged(runs)
        for index in runs.indices.dropFirst().dropLast() where length(runs[index]) < shortest {
            if runs[index - 1].quality == runs[index + 1].quality { runs[index].quality = runs[index - 1].quality }
        }
        return merged(runs).compactMap { run in
            guard let quality = run.quality, length(run) >= shortest else { return nil }
            return WiFiForecast.Stretch(quality: quality, start: Double(run.start) * step, end: Double(run.end) * step)
        }
    }

    static func key(_ index: (Int, Int)) -> String { "\(index.0)|\(index.1)" }
}

/// The Wi-Fi on the track ahead, from earlier rides.
public struct WiFiForecast: Sendable, Equatable {
    public struct Stretch: Sendable, Equatable {
        public var quality: Internet.Quality
        /// Meters ahead of the train.
        public var start: Double
        public var end: Double
    }

    /// In order; parts no earlier ride covered are left out.
    public var stretches: [Stretch]
    /// The train's speed in m/s, which turns distances into times.
    public var speed: Double
    public var date: Date

    public func time(at distance: Double) -> Date { date.addingTimeInterval(distance / speed) }

    /// The first stretch ahead of the train with Wi-Fi other than `current`. A stretch the train is in already says
    /// nothing the live level doesn't.
    public func next(after current: Internet.Quality) -> Stretch? {
        stretches.first { $0.start > 0 && $0.quality != current }
    }

    /// `internet` with the change ahead filled in, unless the portal sent its own.
    public func filling(_ internet: Internet) -> Internet {
        guard internet.next == nil, let next = next(after: internet.current) else { return internet }
        return Internet(current: internet.current, next: next.quality, nextChange: time(at: next.start), learned: true)
    }

    /// The first offline stretch ahead of the train lasting at least `duration` at its speed.
    public func deadZone(lasting duration: TimeInterval) -> Stretch? {
        stretches.first { $0.quality == .none && $0.start > 0 && ($0.end - $0.start) / speed >= duration }
    }
}

/// Follows the train along its route on board and turns the portal's Wi-Fi level into one verdict per grid cell
/// and ride. Between the portal's GPS fixes, which change only every few seconds, and in tunnels, where there are
/// none, it carries the train on along the route at its speed.
public struct WiFiTracker: Sendable {
    public typealias Verdict = (quality: Internet.Quality, coordinate: Coordinate)

    private struct Cell: Sendable {
        var lat: Int
        var lon: Int
        var coordinate: Coordinate
        /// Samples per level, best first.
        var counts = [0, 0, 0]
    }

    /// Where the train is, in meters along its route; `nil` without a route or a GPS fix on it.
    public private(set) var along: Double?
    private var train: String?
    private var route: Route?
    private var fix: Coordinate?
    private var heading: Double?
    private var updated: Date?
    /// Meters carried on since the last fix.
    private var carried = 0.0
    private var cell: Cell?
    /// Cells with a verdict from this ride: one per ride, however long the train stood there or jittered across.
    private var judged: Set<String> = []

    /// Carried on without a fix for longer than this, the position is too uncertain.
    static let reach = 20_000.0
    /// After a gap this long between updates (sleep, the portal gone) the train isn't carried on.
    static let gap: TimeInterval = 60

    public init() {}

    /// Takes the next on-board status; returns verdicts on the cells the train has left.
    public mutating func update(_ status: TrainStatus, at date: Date) -> [Verdict] {
        var verdicts: [Verdict] = []
        let name = status.trainName ?? ""
        if train.map({ !TrainName.same($0, name) }) ?? true {
            // Another train: a new ride.
            if let verdict = finishCell() { verdicts.append(verdict) }
            self = WiFiTracker()
            train = name
        }
        if route != status.route {
            route = status.route
            along = nil
        }

        let elapsed = updated.map { date.timeIntervalSince($0) } ?? 0
        updated = date
        if let position = status.position, position != fix {
            if elapsed > Self.gap {
                heading = nil
            } else if let fix, fix.distance(to: position) * 1000 >= 20 {
                heading = fix.bearing(to: position)
            }
            fix = position
            carried = 0
            along = route.flatMap { route in
                let found = route.projection(of: position, heading: heading)
                return found.offset < 0.5 ? found.along : nil
            }
        } else if let current = along, let route, let speed = status.speed, (0...Self.gap).contains(elapsed) {
            // The same fix as before, or none in a tunnel.
            let step = Double(speed) / 3.6 * elapsed
            carried += step
            along = carried <= Self.reach ? min(current + step, route.length) : nil
        } else {
            along = nil
        }

        guard let here = along.flatMap({ route?.coordinate(at: $0) }) ?? status.position,
              let quality = status.internet?.current
        else { return verdicts }
        let (lat, lon) = LearnedSpeeds.index(here)
        if let cell, cell.lat != lat || cell.lon != lon, let verdict = finishCell() { verdicts.append(verdict) }
        if cell?.lat != lat || cell?.lon != lon { cell = Cell(lat: lat, lon: lon, coordinate: here) }
        cell?.counts[quality.severity] += 1
        return verdicts
    }

    /// The level the train mostly had in the cell it's leaving, the worse one on a tie.
    private mutating func finishCell() -> Verdict? {
        defer { cell = nil }
        guard let cell, judged.insert(LearnedWiFi.key((cell.lat, cell.lon))).inserted else { return nil }
        var level = Internet.Quality.none
        for quality in [Internet.Quality.weak, .good] where cell.counts[quality.severity] > cell.counts[level.severity] {
            level = quality
        }
        return (level, cell.coordinate)
    }
}

/// When to warn about a long offline stretch ahead: once per stretch, a little before it.
public struct DeadZoneAlert: Sendable {
    /// Offline stretches shorter than this aren't worth a warning.
    public static let shortest: TimeInterval = 3 * 60
    /// How long before the stretch the warning comes.
    public static let lead: TimeInterval = 2 * 60

    private var quietUntil: Date?

    public init() {}

    /// The offline stretch to warn about now, with when it starts and ends at the train's speed.
    public mutating func check(_ forecast: WiFiForecast, current: Internet.Quality, at date: Date) -> (start: Date, end: Date)? {
        guard current != .none, quietUntil.map({ date >= $0 }) ?? true,
              let zone = forecast.deadZone(lasting: Self.shortest)
        else { return nil }
        let (start, end) = (forecast.time(at: zone.start), forecast.time(at: zone.end))
        guard start.timeIntervalSince(date) <= Self.lead else { return nil }
        quietUntil = end.addingTimeInterval(60)
        return (start, end)
    }
}

extension Internet.Quality {
    /// 0 for good, 1 for weak, 2 for offline.
    var severity: Int {
        switch self {
        case .good: 0
        case .weak: 1
        case .none: 2
        }
    }
}
