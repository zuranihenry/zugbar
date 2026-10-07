import Foundation

/// How fast trains actually ran where, learned from on-board GPS. Stored per ~280 m grid cell and train kind
/// as the highest observed speed and a count; no trips, times or tracks, so it stays anonymous.
public struct LearnedSpeeds: Codable, Sendable, Equatable {
    struct Cell: Codable, Sendable, Equatable {
        var count: Int
        var maxSpeed: Int
    }

    /// Grid size in degrees: about 280 m north-south, 280 m east-west at 50°N.
    static let latStep = 0.0025
    static let lonStep = 0.004

    private var cells: [String: Cell] = [:]

    public init() {}

    public var cellCount: Int { cells.count }

    /// Records one observation. Below 15 km/h the train is stopping or shunting; that says nothing about the line.
    public mutating func record(_ coordinate: Coordinate, speed: Int, kind: TrainKind) {
        guard speed >= 15, speed <= 400 else { return }
        let key = Self.key(Self.index(coordinate), kind: kind)
        var cell = cells[key] ?? Cell(count: 0, maxSpeed: 0)
        cell.count += 1
        cell.maxSpeed = max(cell.maxSpeed, speed)
        cells[key] = cell
    }

    /// The fastest this kind of train was seen around `coordinate` (its cell and the eight around it),
    /// once there are at least two observations.
    public func cap(at coordinate: Coordinate, kind: TrainKind) -> Int? {
        let (lat, lon) = Self.index(coordinate)
        var count = 0, fastest = 0
        for dLat in -1...1 {
            for dLon in -1...1 {
                guard let cell = cells[Self.key((lat + dLat, lon + dLon), kind: kind)] else { continue }
                count += cell.count
                fastest = max(fastest, cell.maxSpeed)
            }
        }
        return count >= 2 ? fastest + 5 : nil
    }

    /// Lowers `limits` (one per evenly spaced sample along `points`) to what was actually observed.
    /// Returns the new limits and how many samples had learned data.
    public func apply(to limits: [Int], along points: [Coordinate], kind: TrainKind) -> (limits: [Int], covered: Int) {
        guard limits.count >= 2, points.count >= 2 else { return (limits, 0) }
        let route = Route(points: points)
        var covered = 0
        let adjusted = limits.enumerated().map { index, limit in
            guard let point = route.coordinate(at: route.length * Double(index) / Double(limits.count - 1)),
                  let learned = cap(at: point, kind: kind)
            else { return limit }
            covered += 1
            return min(limit, learned)
        }
        return (adjusted, covered)
    }

    static func index(_ coordinate: Coordinate) -> (Int, Int) {
        (Int((coordinate.latitude / latStep).rounded(.down)), Int((coordinate.longitude / lonStep).rounded(.down)))
    }

    static func key(_ index: (Int, Int), kind: TrainKind) -> String {
        "\(kind.maxSpeed)|\(index.0)|\(index.1)"
    }
}
