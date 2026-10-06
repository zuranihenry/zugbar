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

        let base = Double(status.speed ?? 200)
        status.speed = Int(base + 25 * sin(now.timeIntervalSince(startedAt) / 20))
        return status
    }

    public static func resource(_ name: String) throws -> Data {
        // The packaged .app keeps these in Contents/Resources; `swift run` uses the SwiftPM bundle.
        let url = Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
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
