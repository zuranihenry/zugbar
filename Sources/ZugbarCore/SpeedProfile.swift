import Foundation

/// A plausible speed curve for one section between two stops: accelerate, run at the line's speed limits,
/// brake for the next stop, all scaled so the trip takes as long as the timetable says.
public struct SpeedProfile: Sendable, Equatable {
    /// Sample spacing in meters.
    static let step = 100.0
    static let acceleration = 0.4 // m/s²
    static let braking = 0.6 // m/s²

    /// Speed in m/s at each sample, and the time each sample is reached.
    let speeds: [Double]
    let times: [TimeInterval]
    let step: Double

    /// `limits` are km/h per sample along the section (`length / step + 1` values).
    public init?(length: Double, limits: [Int], duration: TimeInterval) {
        guard length > 0, duration > 0, limits.count >= 2 else { return nil }
        let step = length / Double(limits.count - 1)
        let caps = limits.map { Double(max($0, 30)) / 3.6 }

        func profile(scale: Double) -> (speeds: [Double], time: TimeInterval) {
            var v = caps.map { $0 * scale }
            v[0] = 0
            v[v.count - 1] = 0
            // Forward pass: how fast the train can be after accelerating; backward: how fast it may be to stop in time.
            for i in 1..<v.count { v[i] = min(v[i], sqrt(v[i - 1] * v[i - 1] + 2 * Self.acceleration * step)) }
            for i in stride(from: v.count - 2, through: 0, by: -1) { v[i] = min(v[i], sqrt(v[i + 1] * v[i + 1] + 2 * Self.braking * step)) }
            var time = 0.0
            for i in 1..<v.count { time += step / max((v[i - 1] + v[i]) / 2, 0.5) }
            return (v, time)
        }

        // Find how close to the limits the train must run to match the timetable.
        var low = 0.15, high = 1.0
        var best = profile(scale: high)
        if best.time < duration {
            for _ in 0..<30 {
                let mid = (low + high) / 2
                let candidate = profile(scale: mid)
                if candidate.time > duration { low = mid } else { high = mid; best = candidate }
            }
        }

        var times = [0.0]
        for i in 1..<best.speeds.count {
            times.append(times[i - 1] + step / max((best.speeds[i - 1] + best.speeds[i]) / 2, 0.5))
        }
        // Stretch to the timetable when the train can't make it even at the limit (late running, missing data).
        let stretch = duration / (times.last ?? duration)
        self.times = times.map { $0 * stretch }
        self.speeds = best.speeds.map { $0 / stretch }
        self.step = step
    }

    /// Speed (km/h) and distance into the section (m) after `elapsed` seconds.
    public func state(after elapsed: TimeInterval) -> (speed: Int, distance: Double) {
        guard elapsed > 0 else { return (0, 0) }
        guard let upper = times.firstIndex(where: { $0 >= elapsed }) else { return (0, step * Double(speeds.count - 1)) }
        guard upper > 0 else { return (0, 0) }
        let lower = upper - 1
        let t = (elapsed - times[lower]) / max(times[upper] - times[lower], 0.001)
        let speed = speeds[lower] + (speeds[upper] - speeds[lower]) * t
        return (Int((speed * 3.6).rounded()), step * (Double(lower) + t))
    }

    /// Assigns each sample a speed limit from the tracks around it, filling gaps from neighbors.
    public static func limits(along points: [Coordinate], samples: Int, tracks: [TrackLimit]) -> [Int] {
        guard samples >= 2, points.count >= 2 else { return [] }
        let route = Route(points: points)
        var limits: [Int?] = (0..<samples).map { index in
            guard let point = route.coordinate(at: route.length * Double(index) / Double(samples - 1)) else { return nil }
            // Several tracks run side by side near stations; the fastest one close by is usually the main line,
            // the slower ones are sidings. Fall back to the nearest track within 60 m.
            var fastestClose: Int?
            var nearest: (Int, Double)?
            for track in tracks where track.isNear(point) {
                let d = track.nodes.map { $0.distance(to: point) }.min() ?? .infinity
                if d < 0.03 { fastestClose = max(fastestClose ?? 0, track.maxspeed) }
                if d < 0.06, d < (nearest?.1 ?? .infinity) { nearest = (track.maxspeed, d) }
            }
            return fastestClose ?? nearest?.0
        }
        // Fill gaps with the last known limit (or the next one at the start), 120 km/h without any data.
        var last = limits.compactMap { $0 }.first ?? 120
        for i in limits.indices {
            if let value = limits[i] { last = value } else { limits[i] = last }
        }
        return limits.map { $0 ?? 120 }
    }
}

/// A railway track with its posted speed limit, from OpenStreetMap.
public struct TrackLimit: Sendable, Equatable {
    public let maxspeed: Int
    public let nodes: [Coordinate]
    private let south, north, west, east: Double

    public init(maxspeed: Int, nodes: [Coordinate]) {
        self.maxspeed = maxspeed
        self.nodes = nodes
        south = nodes.map(\.latitude).min() ?? 0
        north = nodes.map(\.latitude).max() ?? 0
        west = nodes.map(\.longitude).min() ?? 0
        east = nodes.map(\.longitude).max() ?? 0
    }

    /// Cheap bounding-box check (about 100 m margin) before measuring distances.
    func isNear(_ point: Coordinate) -> Bool {
        point.latitude >= south - 0.001 && point.latitude <= north + 0.001
            && point.longitude >= west - 0.0015 && point.longitude <= east + 0.0015
    }
}

/// Speed limits from OpenStreetMap via Overpass. Public instances are shared; queries are small and cached by the caller.
public struct OverpassClient: Sendable {
    static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]

    let post: @Sendable (URL, Data) async throws -> Data

    public init(post: (@Sendable (URL, Data) async throws -> Data)? = nil) {
        self.post = post ?? { url, body in
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("Zugbar/1.0 (+https://github.com/zuranihenry/zugbar)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw ProviderError.badStatus(http.statusCode) }
            return data
        }
    }

    /// Tagged railway tracks within 25 m of the given points (thinned to about every 1.5 km).
    public func tracks(along points: [Coordinate]) async throws -> [TrackLimit] {
        let route = Route(points: points)
        let count = max(2, min(80, Int(route.length / 1500) + 2))
        let samples = (0..<count).compactMap { route.coordinate(at: route.length * Double($0) / Double(count - 1)) }
        let line = samples.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let query = "[out:json][timeout:25];way(around:25,\(line))[railway=rail][maxspeed];out tags geom qt;"
        let body = Data(("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).utf8)

        var lastError: Error = ProviderError.badStatus(0)
        for endpoint in Self.endpoints {
            do { return try Self.parse(await post(endpoint, body)) } catch { lastError = error }
        }
        throw lastError
    }

    enum OverpassError: Error { case overloaded(String) }

    static func parse(_ data: Data) throws -> [TrackLimit] {
        struct Response: Decodable { let elements: [Element]; let remark: String? }
        struct Element: Decodable {
            let tags: [String: String]?
            let geometry: [Node]?
        }
        struct Node: Decodable { let lat: Double; let lon: Double }

        let response = try JSONDecoder().decode(Response.self, from: data)
        // An overloaded server answers 200 with a "runtime error" remark and no elements.
        if let remark = response.remark, remark.contains("error") { throw OverpassError.overloaded(remark) }
        return response.elements.compactMap { element in
            // "160", "200;160" (per direction), "250 km/h": take the first number.
            guard let raw = element.tags?["maxspeed"],
                  let speed = Int(raw.prefix { $0.isNumber }), speed > 0,
                  let geometry = element.geometry, !geometry.isEmpty
            else { return nil }
            return TrackLimit(maxspeed: speed, nodes: geometry.map { Coordinate(latitude: $0.lat, longitude: $0.lon) })
        }
    }
}
