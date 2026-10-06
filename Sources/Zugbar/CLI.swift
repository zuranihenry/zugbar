import Foundation
import ZugbarCore

enum CLI {
    enum Command: Sendable {
        case lookup(String)
        case departures(station: String, line: String)
        case profile(String)
        case help

        init?(arguments: [String]) {
            let args = Array(arguments.dropFirst())
            switch args.first {
            case "--lookup" where args.count >= 2:
                self = .lookup(args[1])
            case "--departures" where args.count >= 2:
                self = .departures(station: args[1], line: args.count >= 3 ? args[2] : "")
            case "--profile" where args.count >= 2:
                self = .profile(args[1])
            case "--help", "-h":
                self = .help
            default:
                return nil
            }
        }

        func run() async {
            do {
                switch self {
                case .lookup(let query):
                    try await printStatus(Transitous(query: query).fetch())
                case .departures(let station, let line):
                    try await departures(station: station, line: line)
                case .profile(let train):
                    try await profile(train)
                case .help:
                    print("""
                    Usage: Zugbar [--demo]
                           Zugbar --lookup "ICE 591"
                           Zugbar --departures "Köln Hbf" [RE5]
                           Zugbar --profile "ICE 591"
                    """)
                }
            } catch {
                print("Error: \(error)")
            }
        }

        private func departures(station text: String, line: String) async throws {
            let client = TransitousClient()
            guard let station = try await client.stations(matching: text).first else {
                print("No station found for \(text).")
                return
            }
            let departures = TransitousClient.filter(try await client.departures(from: station), line: line)
            print("\(station.name): \(departures.count) departures")
            for departure in departures.prefix(10) {
                let delay = departure.delayMinutes.map { $0 != 0 ? " +\($0)" : "" } ?? ""
                let cancelled = departure.cancelled ? "  cancelled" : ""
                print("  \(time(departure.time))\(delay)  \(departure.displayName) → \(departure.headsign ?? "?")  \(departure.track ?? "")\(cancelled)")
            }
            if let first = departures.first {
                print()
                try await printStatus(Transitous(tripID: first.tripID, label: first.displayName).fetch())
            }
        }

        /// Compares the track-length average and the speed profile for the current section.
        private func profile(_ train: String) async throws {
            let status = try await Transitous(query: train).fetch()
            let now = Date()
            guard let route = status.route, let estimate = status.routeEstimate(at: now),
                  let from = status.stops.first(where: { $0.id == estimate.previousStopID }),
                  let to = status.stops.first(where: { $0.id == estimate.nextStopID })
            else {
                print("\(train): no route, or not between two stops right now.")
                return
            }
            print("\(status.trainName ?? train): \(from.name) → \(to.name)")
            print("  track \(Int(estimate.sectionLength / 1000)) km, \(Int(estimate.duration / 60)) min, ⌀ \(estimate.averageSpeed) km/h")
            let points = route.points(from: estimate.startDistance, to: estimate.endDistance)
            let started = Date()
            let tracks = try await OverpassClient().tracks(along: points)
            guard !tracks.isEmpty else {
                print("  OpenStreetMap returned no tracks; the app would fall back to ⌀ \(estimate.averageSpeed) km/h.")
                return
            }
            let samples = min(2000, max(2, Int(estimate.sectionLength / 100) + 1))
            let limits = SpeedProfile.limits(along: points, samples: samples, tracks: tracks)
            print("  \(tracks.count) tracks in \(String(format: "%.1f", Date().timeIntervalSince(started))) s, limits \(Set(limits).sorted())")
            guard let profile = SpeedProfile(length: estimate.sectionLength, limits: limits, duration: estimate.duration, kind: estimate.kind) else { return }
            for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
                let state = profile.state(after: estimate.duration * fraction)
                print(String(format: "  %3.0f%%  %3d km/h  %5.1f km", fraction * 100, state.speed, state.distance / 1000))
            }
            let current = profile.state(after: now.timeIntervalSince(estimate.departure))
            print("  now: \(current.speed) km/h (profile) vs ⌀ \(estimate.averageSpeed) km/h")
        }

        private func printStatus(_ status: TrainStatus) {
            print("\(status.trainName ?? "?") → \(status.destination ?? "?")")
            for stop in status.stops {
                let delay = stop.delayMinutes.map { $0 != 0 ? " +\($0)" : "" } ?? ""
                print("  \(stop.passed ? "✓" : "·") \(time(stop.arrival ?? stop.departure))\(delay)  \(stop.name)  \(stop.track ?? "")")
            }
        }

        private func time(_ date: Date?) -> String {
            date?.formatted(date: .omitted, time: .shortened) ?? "--:--"
        }
    }
}
