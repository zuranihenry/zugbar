import Foundation

/// A train's path as a polyline, with distances along it. Lets positions follow the tracks
/// and speeds use track length instead of straight lines.
public struct Route: Sendable, Equatable {
    public let points: [Coordinate]
    /// Meters from the start to each point.
    let distances: [Double]

    public init(points: [Coordinate]) {
        self.points = points
        var distances = [0.0]
        distances.reserveCapacity(points.count)
        for index in points.indices.dropFirst() {
            distances.append(distances[index - 1] + points[index - 1].distance(to: points[index]) * 1000)
        }
        self.distances = distances
    }

    public var length: Double { distances.last ?? 0 }

    /// Distance along the route of the point closest to `coordinate`, searching from `start` meters on.
    public func distance(of coordinate: Coordinate, from start: Double = 0) -> Double {
        let first = distances.firstIndex { $0 >= start } ?? 0
        var best = first, bestDistance = Double.infinity
        for index in first..<points.count {
            let d = points[index].distance(to: coordinate)
            if d < bestDistance { bestDistance = d; best = index }
        }
        return distances[best]
    }

    /// Where `coordinate` lies on the track: meters along the route, km off it, and the length in meters of the
    /// piece of line it's closest to. Projects onto each piece rather than taking the nearest point, so a fix in the
    /// middle of a long straight stretch counts as on the line.
    /// With a `heading`, only pieces going that way count, so where a train comes back the same way after
    /// reversing, the fix lands on the right leg.
    public func projection(of coordinate: Coordinate, heading: Double? = nil) -> (along: Double, offset: Double, pieceLength: Double) {
        guard points.count > 1 else { return (0, points.first.map { $0.distance(to: coordinate) } ?? .infinity, 0) }
        if let heading {
            let found = projection(of: coordinate) { a, b in
                a.distance(to: b) < 0.02 || abs((a.bearing(to: b) - heading + 540).truncatingRemainder(dividingBy: 360) - 180) < 90
            }
            if found.offset.isFinite { return found }
        }
        return projection(of: coordinate) { _, _ in true }
    }

    private func projection(of coordinate: Coordinate, counts: (Coordinate, Coordinate) -> Bool) -> (along: Double, offset: Double, pieceLength: Double) {
        var best = (along: 0.0, offset: Double.infinity, pieceLength: 0.0)
        for index in points.indices.dropLast() where counts(points[index], points[index + 1]) {
            let (along, offset) = project(coordinate, onPiece: index)
            if offset < best.offset { best = (along, offset, distances[index + 1] - distances[index]) }
        }
        return best
    }

    /// Where a stop lies on the track, `start` meters on or later: on the first leg that passes it, not the nearest
    /// one anywhere, so a stop the train comes back to after reversing, or on a circular trip, gets its own visit.
    public func along(of coordinate: Coordinate, from start: Double) -> Double {
        guard points.count > 1 else { return start }
        var candidates: [(along: Double, offset: Double)] = []
        for index in points.indices.dropLast() where distances[index + 1] >= start {
            candidates.append(project(coordinate, onPiece: index, from: start))
        }
        guard let closest = candidates.map(\.offset).min() else { return start }
        // The first leg about as close as the closest one: two legs on the same track are only meters apart.
        return candidates.first { $0.offset <= closest + 0.05 }?.along ?? start
    }

    /// Meters along the route and km off it of `coordinate` projected onto the piece starting at `index`,
    /// not before `start`.
    private func project(_ coordinate: Coordinate, onPiece index: Int, from start: Double = 0) -> (along: Double, offset: Double) {
        let (a, b) = (points[index], points[index + 1])
        // Flat frame around the piece's start, in km.
        let scale = cos(a.latitude * .pi / 180)
        let (dx, dy) = ((b.longitude - a.longitude) * 111.32 * scale, (b.latitude - a.latitude) * 110.57)
        let (px, py) = ((coordinate.longitude - a.longitude) * 111.32 * scale, (coordinate.latitude - a.latitude) * 110.57)
        let lengthSquared = dx * dx + dy * dy
        let pieceLength = distances[index + 1] - distances[index]
        let lowest = pieceLength > 0 ? min(max((start - distances[index]) / pieceLength, 0), 1) : 0
        let t = lengthSquared > 0 ? min(max((px * dx + py * dy) / lengthSquared, lowest), 1) : lowest
        let (ox, oy) = (px - dx * t, py - dy * t)
        return (distances[index] + pieceLength * t, (ox * ox + oy * oy).squareRoot())
    }

    /// Compass bearing of the track at `distance`, over the next 200 m; nil where the route has no length.
    public func bearing(at distance: Double) -> Double? {
        let start = min(max(distance, 0), max(length - 200, 0))
        guard let a = coordinate(at: start), let b = coordinate(at: start + 200), a.distance(to: b) > 0.02 else { return nil }
        return a.bearing(to: b)
    }

    public func coordinate(at distance: Double) -> Coordinate? {
        guard let last = points.last else { return nil }
        guard distance > 0 else { return points.first }
        guard distance < length else { return last }
        // Binary search: called every frame while the map follows a train.
        var low = 0, high = distances.count - 1
        while low < high {
            let mid = (low + high) / 2
            if distances[mid] < distance { low = mid + 1 } else { high = mid }
        }
        let upper = low
        guard upper > 0 else { return points[0] }
        let lower = upper - 1
        let span = distances[upper] - distances[lower]
        let t = span > 0 ? (distance - distances[lower]) / span : 0
        let a = points[lower], b = points[upper]
        return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// The points between two distances, for querying speed limits along a section.
    public func points(from start: Double, to end: Double) -> [Coordinate] {
        zip(points, distances).filter { $0.1 >= start && $0.1 <= end }.map(\.0)
    }

    /// Decodes a Google encoded polyline.
    public static func decode(_ encoded: String, precision: Int = 5) -> [Coordinate] {
        var coordinates: [Coordinate] = []
        var index = encoded.startIndex
        var latitude = 0, longitude = 0
        let factor = pow(10, Double(precision))

        func next() -> Int? {
            var result = 0, shift = 0
            while index < encoded.endIndex {
                let byte = Int(encoded.unicodeScalars[index].value) - 63
                index = encoded.index(after: index)
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }

        while index < encoded.endIndex {
            guard let dLat = next(), let dLon = next() else { break }
            latitude += dLat
            longitude += dLon
            coordinates.append(Coordinate(latitude: Double(latitude) / factor, longitude: Double(longitude) / factor))
        }
        return coordinates
    }
}

/// Where a train is between two stops along its route, estimated from the timetable.
public struct RouteEstimate: Sendable, Equatable {
    public let previousStopID: String
    public let nextStopID: String
    /// Meters along the route.
    public let startDistance: Double
    public let endDistance: Double
    public let departure: Date
    public let arrival: Date
    public var kind: TrainKind = .highSpeed

    public var sectionLength: Double { endDistance - startDistance }
    public var duration: TimeInterval { arrival.timeIntervalSince(departure) }
    public var key: String { "\(previousStopID)→\(nextStopID)" }

    /// Average speed over the section, km/h.
    public var averageSpeed: Int { Int((sectionLength / duration * 3.6).rounded()) }

    /// Accelerate, cruise, brake, without knowing the line's speed limits. Better than a flat average
    /// right after departure and before arrival.
    public var basicProfile: SpeedProfile? {
        let cap = min(Double(kind.maxSpeed), max(80, Double(averageSpeed) * 1.4))
        let samples = min(400, max(2, Int(sectionLength / 200) + 1))
        return SpeedProfile(length: sectionLength, limits: Array(repeating: Int(cap), count: samples), duration: duration, kind: kind)
    }
}

extension TrainStatus {
    /// The section the train is on, measured along `route`. `nil` before departure, at a stop or without a route.
    public func routeEstimate(at now: Date) -> RouteEstimate? {
        guard let route, route.length > 0,
              let nextIndex = nextStopIndex(at: now), nextIndex > 0
        else { return nil }
        let previous = stops[nextIndex - 1], next = stops[nextIndex]
        guard let departure = previous.departure, let arrival = next.arrival, arrival > departure,
              !previous.isCurrent(at: now), !next.isCurrent(at: now)
        else { return nil }
        // Placed in order, so a station the train comes back to doesn't stretch the section back over the loop.
        let alongs = stopAlongs(on: route)
        guard let start = alongs[nextIndex - 1], let end = alongs[nextIndex], end > start else { return nil }
        return RouteEstimate(previousStopID: previous.id, nextStopID: next.id, startDistance: start, endDistance: end,
                             departure: departure, arrival: arrival, kind: TrainKind.of(trainName))
    }

    /// Meters along `route` of each stop, placed in order: a station the train comes back to after reversing, or on
    /// a circular trip, gets its own visit. `nil` for stops without a coordinate. Remembered per route and stops,
    /// since sections and positions ask for it several times a second.
    public func stopAlongs(on route: Route) -> [Double?] {
        let key = "\(route.points.count)|\(route.length)|" + stops.map { stop in
            stop.id + (stop.coordinate.map { "@\($0.latitude),\($0.longitude)" } ?? "")
        }.joined(separator: ";")
        if let known = StopAlongs.shared.get(key) { return known }
        var previous = 0.0
        let alongs = stops.map { stop in
            stop.coordinate.map { coordinate -> Double in
                previous = route.along(of: coordinate, from: previous)
                return previous
            }
        }
        StopAlongs.shared.set(key, alongs)
        return alongs
    }
}

/// The last few stop placements: the train and a connection, both followed online, ask in turn.
private final class StopAlongs: @unchecked Sendable {
    static let shared = StopAlongs()
    private let lock = NSLock()
    private var placed: [String: [Double?]] = [:]

    func get(_ key: String) -> [Double?]? {
        lock.withLock { placed[key] }
    }

    func set(_ key: String, _ alongs: [Double?]) {
        lock.withLock {
            if placed.count >= 4 { placed.removeAll() }
            placed[key] = alongs
        }
    }
}
