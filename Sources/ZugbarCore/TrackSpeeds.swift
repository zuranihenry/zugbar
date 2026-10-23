import Foundation

/// A route split into stretches of similar posted speed, to color the track on the map.
public enum TrackSpeeds {
    public struct Stretch: Sendable, Equatable {
        public var points: [Coordinate]
        /// Top speed of the stretch's band in km/h (see `band(of:)`); nil where no limit is known.
        public var band: Int?
    }

    /// The speeds the map tells apart: up to 120, 160, 200, 250 and above.
    public static let bands = [120, 160, 200, 250, 300]

    public static func band(of limit: Int?) -> Int? {
        guard let limit else { return nil }
        return bands.first { limit <= $0 } ?? bands.last
    }

    /// Stretches along `points`, looked up at each point and at least every `step` meters, so long straight
    /// pieces don't skip a change. Each stretch starts where the one before ended, so the line has no gaps.
    public static func stretches(along points: [Coordinate], step: Double = 250, limit: (Coordinate) -> Int?) -> [Stretch] {
        let route = Route(points: points)
        guard route.length > 0 else { return [] }
        let distances = Set(route.distances + stride(from: 0, to: route.length, by: step)).sorted()
        var stretches: [Stretch] = []
        for distance in distances {
            guard let point = route.coordinate(at: distance) else { continue }
            let band = band(of: limit(point))
            if let last = stretches.last, last.band == band {
                stretches[stretches.count - 1].points.append(point)
            } else {
                stretches.append(Stretch(points: [stretches.last?.points.last, point].compactMap { $0 }, band: band))
            }
        }
        return stretches
    }
}
