import Foundation

/// Replays recorded portal responses, shifted so the next stop is a few minutes away.
public struct DemoProvider: TrainProvider {
    public enum Recording: Sendable {
        case deutscheBahn, oebb
    }

    public let recording: Recording
    public var name: String { recording == .deutscheBahn ? "Demo (DB)" : "Demo (ÖBB)" }

    private let startedAt = Date()

    public init(recording: Recording = .deutscheBahn) {
        self.recording = recording
    }

    public func fetch() async throws -> TrainStatus {
        let now = Date()
        var status = switch recording {
        case .deutscheBahn:
            try ICEPortal.parse(status: Self.resource("demo_db_status"), trip: Self.resource("demo_db_trip"))
        case .oebb:
            try OEBBRailnet.parse(combined: Self.resource("demo_oebb"), now: now)
        }
        status.provider = name

        let scenario = await DemoScenario.shared.snapshot
        if let arrival = status.nextStop?.arrival {
            let shift = startedAt.addingTimeInterval(9 * 60).timeIntervalSince(arrival) - scenario.timeShift
            status.stops = status.stops.map { $0.shifted(by: shift) }
        }
        status.stops = status.stops.map { stop in
            guard !stop.passed else { return stop }
            var stop = stop
            let delay = TimeInterval(scenario.extraDelay * 60)
            stop.expectedArrival = stop.expectedArrival.map { $0.addingTimeInterval(delay) }
            stop.expectedDeparture = stop.expectedDeparture.map { $0.addingTimeInterval(delay) }
            if let track = scenario.trackOverride { stop.track = track }
            return stop
        }

        if recording == .deutscheBahn, let route = Self.route {
            // The recording has one GPS fix; drive the train along the real track instead, so the map,
            // following and heading can be tried out.
            status.route = route
            if let (position, speed) = Self.drive(status, along: route, at: now) {
                status.position = position
                status.speed = speed
            }
        } else {
            let base = Double(status.speed ?? 200)
            status.speed = Int(base + 25 * sin(now.timeIntervalSince(startedAt) / 20))
        }
        return status
    }

    /// The demo ICE's track, Berlin Hbf – München Hbf, from Transitous.
    static let route: Route? = (try? resource("demo_route")).flatMap { data in
        struct File: Decodable { let polyline: String }
        return (try? JSONDecoder().decode(File.self, from: data)).map { Route(points: Route.decode($0.polyline)) }
    }

    /// Where the train is between its last and next stop at `now`, accelerating and braking like a real one.
    static func drive(_ status: TrainStatus, along route: Route, at now: Date) -> (Coordinate, Int)? {
        guard let nextIndex = status.stops.firstIndex(where: { !$0.passed }), nextIndex > 0 else { return nil }
        let previous = status.stops[nextIndex - 1], next = status.stops[nextIndex]
        guard let from = previous.coordinate, let to = next.coordinate,
              let departure = previous.departure, let arrival = next.arrival, arrival > departure
        else { return nil }
        let start = route.distance(of: from)
        let end = route.distance(of: to, from: start)
        guard end > start else { return nil }
        let estimate = RouteEstimate(previousStopID: previous.id, nextStopID: next.id, startDistance: start, endDistance: end,
                                     departure: departure, arrival: arrival, kind: TrainKind.of(status.trainName))
        guard let profile = SpeedProfile(length: estimate.sectionLength, limits: Array(repeating: 300, count: 400),
                                         duration: estimate.duration, kind: estimate.kind),
              let position = route.coordinate(at: start + profile.state(after: now.timeIntervalSince(departure)).distance)
        else { return nil }
        return (position, profile.state(after: now.timeIntervalSince(departure)).speed)
    }

    public static func resource(_ name: String, extension: String = "json") throws -> Data {
        // The packaged .app keeps these in Contents/Resources; `swift run` uses the SwiftPM bundle.
        let url = Bundle.main.url(forResource: name, withExtension: `extension`)
            ?? Bundle.module.url(forResource: name, withExtension: `extension`, subdirectory: "Resources")
        guard let url else { throw ProviderError.missingResource(name) }
        return try Data(contentsOf: url)
    }
}

/// Knobs for testing notifications against the demo train (Settings → Debug).
public actor DemoScenario {
    public static let shared = DemoScenario()

    public struct Snapshot: Sendable {
        public var extraDelay = 0
        public var trackOverride: String?
        /// Moves the whole timetable earlier, as if time passed faster.
        public var timeShift: TimeInterval = 0
    }

    public private(set) var snapshot = Snapshot()

    public func addDelay(_ minutes: Int) { snapshot.extraDelay += minutes }
    public func changeTrack() { snapshot.trackOverride = String(Int.random(in: 1...20)) }
    public func skipAhead(minutes: Int) { snapshot.timeShift += TimeInterval(minutes * 60) }
    public func reset() { snapshot = Snapshot() }
}
