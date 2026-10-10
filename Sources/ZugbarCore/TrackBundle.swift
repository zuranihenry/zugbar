import Foundation

/// Speed limits of main-line tracks shipped with the app, from OpenStreetMap (© OpenStreetMap contributors, ODbL),
/// so track profiles work instantly and offline instead of waiting for an often overloaded public Overpass server.
/// Built by `Zugbar --bundle-tracks`; sections off these lines still go online.
public struct TrackBundle: Sendable {
    public let date: String
    let tracks: [TrackLimit]
    /// Track indices by grid cell of about 5 km.
    private let grid: [Cell: [Int]]

    private struct Cell: Hashable {
        let lat: Int, lon: Int

        init(_ coordinate: Coordinate) {
            lat = Int((coordinate.latitude / TrackBundle.cellSize).rounded(.down))
            lon = Int((coordinate.longitude / TrackBundle.cellSize).rounded(.down))
        }

        init(lat: Int, lon: Int) {
            self.lat = lat
            self.lon = lon
        }

        var neighbors: [Cell] {
            (-1...1).flatMap { dLat in (-1...1).map { dLon in Cell(lat: lat + dLat, lon: lon + dLon) } }
        }
    }

    static let cellSize = 0.05
    /// Coordinates are stored as integers of this many degrees.
    static let scale = 1e-5

    /// The bundle in the app's resources, decoded on first use; `nil` if it's missing.
    public static let shared: TrackBundle? = (try? DemoProvider.resource("main_line_tracks", extension: "lzfse"))
        .flatMap { try? TrackBundle(compressed: $0) }

    public init(date: String, tracks: [TrackLimit]) {
        self.date = date
        self.tracks = tracks
        var grid: [Cell: [Int]] = [:]
        for (index, track) in tracks.enumerated() {
            // Every cell the line passes through: simplified straight stretches can run for kilometers between nodes.
            var cells = Set(track.nodes.map(Cell.init))
            for (a, b) in zip(track.nodes, track.nodes.dropFirst()) {
                let steps = Int(max(abs(b.latitude - a.latitude), abs(b.longitude - a.longitude)) / (Self.cellSize / 2))
                for step in stride(from: 1, through: steps, by: 1) {
                    let t = Double(step) / Double(steps + 1)
                    cells.insert(Cell(Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                 longitude: a.longitude + (b.longitude - a.longitude) * t)))
                }
            }
            for cell in cells { grid[cell, default: []].append(index) }
        }
        self.grid = grid
    }

    /// Format: `{"version": 1, "date": "…", "tracks": [[maxspeed, lat, lon, Δlat, Δlon, …], …]}` with coordinates
    /// in 1e-5 degrees, each after the first as the difference to the one before. Small and quick to read.
    public init(data: Data) throws {
        struct File: Decodable { let version: Int; let date: String; let tracks: [[Int]] }
        let file = try JSONDecoder().decode(File.self, from: data)
        let tracks = file.tracks.compactMap { values -> TrackLimit? in
            guard values.count >= 5, values.count % 2 == 1 else { return nil }
            var lat = 0, lon = 0
            var nodes: [Coordinate] = []
            nodes.reserveCapacity(values.count / 2)
            for index in stride(from: 1, to: values.count, by: 2) {
                lat += values[index]
                lon += values[index + 1]
                nodes.append(Coordinate(latitude: Double(lat) * Self.scale, longitude: Double(lon) * Self.scale))
            }
            return TrackLimit(maxspeed: values[0], nodes: nodes)
        }
        self.init(date: file.date, tracks: tracks)
    }

    /// The JSON compressed with LZFSE, about a quarter of the size.
    public init(compressed data: Data) throws {
        try self.init(data: (data as NSData).decompressed(using: .lzfse) as Data)
    }

    public func compressed() throws -> Data {
        try (encoded() as NSData).compressed(using: .lzfse) as Data
    }

    public func encoded() throws -> Data {
        struct File: Encodable { let version: Int; let date: String; let tracks: [[Int]] }
        let rows = tracks.map { track -> [Int] in
            var row = [track.maxspeed]
            var lat = 0, lon = 0
            for node in track.nodes {
                let (y, x) = (Int((node.latitude / Self.scale).rounded()), Int((node.longitude / Self.scale).rounded()))
                row += [y - lat, x - lon]
                (lat, lon) = (y, x)
            }
            return row
        }
        return try JSONEncoder().encode(File(version: 1, date: date, tracks: rows))
    }

    /// The bundled tracks along `points`, or `nil` when the bundle doesn't cover the section: nearly every point
    /// (checked about every 500 m) must have a bundled track within 60 m, else a branch line is missing and
    /// Overpass knows better.
    public func tracks(along points: [Coordinate]) -> [TrackLimit]? {
        let route = Route(points: points)
        guard route.length > 0 else { return nil }
        let count = max(2, Int(route.length / 500) + 1)
        let checks = (0..<count).compactMap { route.coordinate(at: route.length * Double($0) / Double(count - 1)) }
        var found = Set<Int>()
        var covered = 0
        for point in checks {
            let candidates = Set(Cell(point).neighbors.flatMap { grid[$0] ?? [] })
            found.formUnion(candidates)
            if candidates.contains(where: { tracks[$0].isNear(point) && tracks[$0].distance(to: point) < 0.06 }) { covered += 1 }
        }
        guard Double(covered) >= Double(checks.count) * 0.95 else { return nil }
        return found.sorted().map { tracks[$0] }
    }
}
