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
        guard let from = previous.coordinate, let to = next.coordinate,
              let departure = previous.departure, let arrival = next.arrival, arrival > departure,
              !previous.isCurrent(at: now), !next.isCurrent(at: now)
        else { return nil }
        let start = route.distance(of: from)
        let end = route.distance(of: to, from: start)
        guard end > start else { return nil }
        return RouteEstimate(previousStopID: previous.id, nextStopID: next.id, startDistance: start, endDistance: end,
                             departure: departure, arrival: arrival, kind: TrainKind.of(trainName))
    }
}
