import Foundation

/// Where a trip went, thinned to a few hundred points. More than one line when the fixes had a gap (a tunnel, the
/// lid closed): the stretch in between isn't known, so it isn't drawn.
public struct TripPath: Codable, Sendable, Equatable {
    public var lines: [[Coordinate]]

    public init(lines: [[Coordinate]]) {
        self.lines = lines
    }

    /// Stored as encoded polylines, a few bytes a point: to the meter is plenty for a line on a map.
    public init(from decoder: Decoder) throws {
        lines = try decoder.singleValueContainer().decode([String].self).map { Route.decode($0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(lines.map { Route.encode($0) })
    }
}

/// Turns the fixes of a trip on board into its path: a point every 200 m. Long trips keep their shape at a coarser
/// step: at `limit` points every other one goes and the spacing doubles, so no trip stores more than that.
public struct PathSampler: Sendable {
    private var lines: [[Coordinate]] = []
    /// The last fix, kept or not: where the line ends.
    private var seen: Coordinate?
    /// Kilometers between points.
    public private(set) var spacing: Double
    let limit: Int
    /// Further than this between two fixes is a gap or a bad fix: the line stops rather than cut the corner.
    static let longestStep = 3.0

    public init(spacing: Double = 0.2, limit: Int = 400) {
        self.spacing = spacing
        self.limit = limit
    }

    /// Goes on from a logged trip's path.
    public init(resuming path: TripPath?, spacing: Double = 0.2, limit: Int = 400) {
        self.init(spacing: spacing, limit: limit)
        lines = path?.lines ?? []
        seen = lines.last?.last
    }

    public mutating func record(_ position: Coordinate) {
        defer { seen = position }
        guard let seen, let last = lines.last?.last, seen.distance(to: position) <= Self.longestStep else {
            endLine()
            lines.append([position])
            return
        }
        guard last.distance(to: position) >= spacing else { return }
        lines[lines.count - 1].append(position)
        if lines.reduce(0, { $0 + $1.count }) >= limit { thin() }
    }

    /// The path so far, each line up to where the train was last seen; `nil` before there is a line to draw.
    public var path: TripPath? {
        var copy = self
        copy.endLine()
        return copy.lines.isEmpty ? nil : TripPath(lines: copy.lines)
    }

    /// Ends the open line at the last fix. A single point is no line: a bad fix, or a glimpse between two gaps.
    private mutating func endLine() {
        guard let seen, let line = lines.last else { return }
        if line.last != seen { lines[lines.count - 1].append(seen) }
        if lines[lines.count - 1].count < 2 { lines.removeLast() }
    }

    private mutating func thin() {
        lines = lines.map { line in
            line.indices.filter { $0 % 2 == 0 || $0 == line.count - 1 }.map { line[$0] }
        }
        spacing *= 2
    }
}

/// Every trip's path as one network, split by how often a stretch was ridden.
public struct TravelledNetwork: Sendable, Equatable {
    /// Lines ridden once, a few times, and often.
    public private(set) var lines: [[[Coordinate]]] = [[], [], []]
    /// Trips with a path, and so on the map.
    public private(set) var tripCount = 0

    /// About a kilometer across in Central Europe: wide enough that two rides on the same line share cells.
    private struct Cell: Hashable {
        var x: Int32
        var y: Int32

        init(_ point: Coordinate) {
            x = Int32((point.longitude / 0.015).rounded(.down))
            y = Int32((point.latitude / 0.01).rounded(.down))
        }
    }

    public init(trips: [Trip]) {
        let paths = trips.compactMap(\.path).filter { !$0.lines.isEmpty }
        tripCount = paths.count
        // How many trips went through each cell.
        var rides: [Cell: Int] = [:]
        for path in paths {
            var cells: Set<Cell> = []
            for line in path.lines {
                for (from, to) in zip(line, line.dropFirst()) {
                    let steps = max(1, Int((from.distance(to: to) / 0.5).rounded(.up)))
                    for step in 0...steps { cells.insert(Cell(Self.point(from, to, Double(step) / Double(steps)))) }
                }
            }
            for cell in cells { rides[cell, default: 0] += 1 }
        }
        /// The neighbors count too: the same track can fall either side of a cell's edge.
        func strength(_ from: Coordinate, _ to: Coordinate) -> Int {
            let cell = Cell(Self.point(from, to, 0.5))
            var most = 1
            for x in -1...1 {
                for y in -1...1 {
                    var near = cell
                    near.x += Int32(x)
                    near.y += Int32(y)
                    most = max(most, rides[near] ?? 0)
                }
            }
            return most >= 5 ? 2 : most >= 2 ? 1 : 0
        }
        for path in paths {
            for line in path.lines where line.count > 1 {
                var run = [line[0]], current = strength(line[0], line[1])
                for (from, to) in zip(line, line.dropFirst()) {
                    let next = strength(from, to)
                    if next != current {
                        lines[current].append(run)
                        run = [from]
                        current = next
                    }
                    run.append(to)
                }
                lines[current].append(run)
            }
        }
    }

    public var isEmpty: Bool { lines.allSatisfy(\.isEmpty) }

    private static func point(_ from: Coordinate, _ to: Coordinate, _ fraction: Double) -> Coordinate {
        Coordinate(latitude: from.latitude + (to.latitude - from.latitude) * fraction,
                   longitude: from.longitude + (to.longitude - from.longitude) * fraction)
    }
}
