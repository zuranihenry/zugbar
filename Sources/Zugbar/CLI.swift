import Foundation
import ZugbarCore

enum CLI {
    enum Command: Sendable {
        case lookup(String)
        case departures(station: String, line: String)
        case profile(String)
        case bundleTracks(String)
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
            case "--bundle-tracks" where args.count >= 2:
                self = .bundleTracks(args[1])
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
                case .bundleTracks(let path):
                    try await bundleTracks(to: path)
                case .help:
                    print("""
                    Usage: Zugbar [--demo]
                           Zugbar --lookup "ICE 591"
                           Zugbar --departures "Köln Hbf" [RE5]
                           Zugbar --profile "ICE 591"
                           Zugbar --bundle-tracks Sources/ZugbarCore/Resources/main_line_tracks.lzfse
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

        /// Downloads speed limits of main-line tracks in and around Germany and Austria from OpenStreetMap, tile by
        /// tile so each query stays small for the public servers, and writes the bundle the app ships with. Takes about
        /// an hour; finished tiles are kept next to the output, so a rerun continues where it stopped.
        private func bundleTracks(to path: String) async throws {
            setvbuf(stdout, nil, _IOLBF, 0)
            let size = 0.5
            // Germany and Austria by bounding box; main lines just across the border come along.
            let boxes = [(south: 47.0, west: 5.5, north: 55.5, east: 15.5), (south: 46.0, west: 9.5, north: 49.5, east: 17.5)]
            var tiles: [(Double, Double)] = []
            for box in boxes {
                for south in stride(from: box.south, to: box.north, by: size) {
                    for west in stride(from: box.west, to: box.east, by: size) where !tiles.contains(where: { $0 == (south, west) }) {
                        tiles.append((south, west))
                    }
                }
            }
            let folder = URL(fileURLWithPath: path + ".tiles", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var ways: [Int: TrackLimit] = [:]
            for (number, (south, west)) in tiles.enumerated() {
                let box = "\(south),\(west),\(south + size),\(west + size)"
                let file = folder.appendingPathComponent(box + ".json")
                let data: Data
                if let saved = try? Data(contentsOf: file) {
                    data = saved
                } else {
                    data = try await overpass("[out:json][timeout:120];way(\(box))[railway=rail][usage=main][maxspeed];out tags geom qt;")
                    try data.write(to: file)
                    try await Task.sleep(for: .seconds(3))
                }
                let found = try OverpassClient.parseWays(data)
                ways.merge(found) { first, _ in first }
                print("\(number + 1)/\(tiles.count) \(box): \(found.count) tracks, \(ways.count) in all")
            }
            let tracks = ways.keys.sorted().compactMap { ways[$0]?.simplified(tolerance: 3) }
            let date = Date().formatted(.iso8601.year().month().day())
            let data = try TrackBundle(date: date, tracks: tracks).compressed()
            try data.write(to: URL(fileURLWithPath: path))
            print("Wrote \(tracks.count) tracks, \(tracks.map(\.nodes.count).reduce(0, +)) nodes, \(data.count / 1024) KB to \(path)")
        }

        /// One query, trying each public server in turn and waiting longer after every round of failures.
        private func overpass(_ query: String) async throws -> Data {
            let servers = ["https://overpass-api.de/api/interpreter", "https://overpass.openstreetmap.fr/api/interpreter",
                           "https://overpass.private.coffee/api/interpreter"]
            var body = URLComponents()
            body.queryItems = [URLQueryItem(name: "data", value: query)]
            for round in 0..<5 {
                for server in servers {
                    var request = URLRequest(url: URL(string: server)!, timeoutInterval: 180)
                    request.httpMethod = "POST"
                    request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
                    request.setValue("Zugbar/1.0 (+https://github.com/zuranihenry/zugbar)", forHTTPHeaderField: "User-Agent")
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          // An overloaded server answers 200 with a "runtime error" remark.
                          (try? OverpassClient.parseWays(data)) != nil
                    else { continue }
                    return data
                }
                print("  all servers failed, retrying in \(30 * (round + 1)) s")
                try await Task.sleep(for: .seconds(30 * (round + 1)))
            }
            throw OverpassClient.OverpassError.unreachable
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
