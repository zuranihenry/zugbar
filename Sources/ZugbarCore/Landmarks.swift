import Foundation

/// One track through a named tunnel, over a named bridge, or over a bridge that crosses a named river.
public struct Landmark: Sendable, Equatable {
    public enum Kind: Int, Sendable { case tunnel = 0, bridge = 1 }

    public let kind: Kind
    /// The tunnel's or bridge's own name; a bridge known only by its river has none.
    public let name: String?
    /// The river a bridge crosses.
    public let river: String?
    /// Length in meters along the track, for tunnels.
    public let length: Int?
    public let nodes: [Coordinate]
    private let shape: TrackLimit

    public init(kind: Kind, name: String?, river: String? = nil, length: Int? = nil, nodes: [Coordinate]) {
        self.kind = kind
        self.name = name
        self.river = river
        self.length = length
        self.nodes = nodes
        shape = TrackLimit(maxspeed: 0, nodes: nodes)
    }

    /// How far GPS and the mapped track may disagree sideways, in meters.
    static let beside = 40.0
    /// How far before or after the mapped ends still counts, in meters: about a coach and a half.
    static let beyondEnd = 15.0
    /// How far the direction of travel may differ from the track's, in degrees. Rules out a line crossing over or under.
    static let turned = 30.0

    /// Distance to the track in meters if `point` is on this stretch, else nil: within `beside` of the line, not
    /// more than `beyondEnd` past either end, and, where a heading is known, travelling along it rather than across.
    func distance(at point: Coordinate, heading: Double? = nil, beside: Double = Landmark.beside,
                  beyondEnd: Double = Landmark.beyondEnd) -> Double? {
        guard nodes.count > 1, shape.isNear(point) else { return nil }
        // Flat projection around the point, in meters; plenty accurate over a few hundred meters.
        let mPerLat = 111_200.0, mPerLon = 111_200 * cos(point.latitude * .pi / 180)
        func xy(_ c: Coordinate) -> (x: Double, y: Double) {
            ((c.longitude - point.longitude) * mPerLon, (c.latitude - point.latitude) * mPerLat)
        }
        // The nearest segment, where along it the point lies (below 0 or above 1: past its ends), and its direction.
        var best: (distance: Double, index: Int, along: Double, length: Double, bearing: Double)?
        var a = xy(nodes[0])
        for index in 1..<nodes.count {
            let b = xy(nodes[index])
            defer { a = b }
            let (dx, dy) = (b.x - a.x, b.y - a.y)
            let squared = dx * dx + dy * dy
            guard squared > 0 else { continue }
            let along = -(a.x * dx + a.y * dy) / squared
            let t = min(max(along, 0), 1)
            let (x, y) = (a.x + t * dx, a.y + t * dy)
            let distance = (x * x + y * y).squareRoot()
            if distance < best?.distance ?? .infinity {
                best = (distance, index, along, squared.squareRoot(), atan2(dx, dy) * 180 / .pi)
            }
        }
        guard let best, best.distance <= beside else { return nil }
        if best.index == 1, best.along < 0, -best.along * best.length > beyondEnd { return nil }
        if best.index == nodes.count - 1, best.along > 1, (best.along - 1) * best.length > beyondEnd { return nil }
        if let heading {
            let difference = abs((heading - best.bearing).truncatingRemainder(dividingBy: 180))
            if min(difference, 180 - difference) > Self.turned { return nil }
        }
        return best.distance
    }

    var meters: Double {
        zip(nodes, nodes.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) * 1000 }
    }
}

/// Named tunnels and bridges on main lines, and the rivers their bridges cross, shipped with the app so naming what
/// the train is passing costs no traffic on board. From OpenStreetMap (© OpenStreetMap contributors, ODbL), built by
/// `Zugbar --bundle-landmarks`.
public struct LandmarkBundle: Sendable {
    public let date: String
    let landmarks: [Landmark]
    private let grid: [GridCell: [Int]]

    /// The bundle in the app's resources, decoded on first use; `nil` if it's missing.
    public static let shared: LandmarkBundle? = (try? DemoProvider.resource("main_line_landmarks", extension: "lzfse"))
        .flatMap { try? LandmarkBundle(compressed: $0) }

    public init(date: String, landmarks: [Landmark]) {
        self.date = date
        self.landmarks = landmarks
        var grid: [GridCell: [Int]] = [:]
        for (index, landmark) in landmarks.enumerated() {
            for cell in GridCell.cells(along: landmark.nodes) { grid[cell, default: []].append(index) }
        }
        self.grid = grid
    }

    /// What a train at `point` is in or on right now, or nil: nothing is named just before or after it. `heading` is
    /// its direction of travel in degrees, if known. A tunnel wins over a bridge, then the nearer track.
    public func landmark(at point: Coordinate, heading: Double? = nil) -> Landmark? {
        Set(GridCell(point).neighbors.flatMap { grid[$0] ?? [] })
            .compactMap { index in landmarks[index].distance(at: point, heading: heading).map { (landmarks[index], $0, index) } }
            .min { ($0.0.kind.rawValue, $0.1, $0.2) < ($1.0.kind.rawValue, $1.1, $1.2) }?.0
    }

    // MARK: File

    private struct File: Codable { let version: Int; let date: String; let names: [String]; let landmarks: [[Int]] }

    /// Format: `{"version": 1, "date": "…", "names": […], "landmarks": [[kind, name, extra, lat, lon, Δlat, Δlon, …], …]}`:
    /// `name` indexes `names` (-1: none), `extra` is a tunnel's length in meters or a bridge's river in `names` (-1: none),
    /// coordinates as in `TrackBundle`.
    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        func name(_ index: Int) -> String? { file.names.indices.contains(index) ? file.names[index] : nil }
        let landmarks = file.landmarks.compactMap { values -> Landmark? in
            guard values.count >= 7, values.count % 2 == 1, let kind = Landmark.Kind(rawValue: values[0]) else { return nil }
            var lat = 0, lon = 0
            var nodes: [Coordinate] = []
            nodes.reserveCapacity(values.count / 2 - 1)
            for index in stride(from: 3, to: values.count, by: 2) {
                lat += values[index]
                lon += values[index + 1]
                nodes.append(Coordinate(latitude: Double(lat) * TrackBundle.scale, longitude: Double(lon) * TrackBundle.scale))
            }
            return Landmark(kind: kind, name: name(values[1]), river: kind == .bridge ? name(values[2]) : nil,
                            length: kind == .tunnel ? values[2] : nil, nodes: nodes)
        }
        self.init(date: file.date, landmarks: landmarks)
    }

    public init(compressed data: Data) throws {
        try self.init(data: (data as NSData).decompressed(using: .lzfse) as Data)
    }

    public func compressed() throws -> Data {
        try (encoded() as NSData).compressed(using: .lzfse) as Data
    }

    public func encoded() throws -> Data {
        var names: [String] = []
        var indices: [String: Int] = [:]
        func index(_ name: String?) -> Int {
            guard let name else { return -1 }
            if let index = indices[name] { return index }
            indices[name] = names.count
            names.append(name)
            return names.count - 1
        }
        let rows = landmarks.map { landmark -> [Int] in
            var row = [landmark.kind.rawValue, index(landmark.name), landmark.kind == .tunnel ? landmark.length ?? 0 : index(landmark.river)]
            var lat = 0, lon = 0
            for node in landmark.nodes {
                let (y, x) = (Int((node.latitude / TrackBundle.scale).rounded()), Int((node.longitude / TrackBundle.scale).rounded()))
                row += [y - lat, x - lon]
                (lat, lon) = (y, x)
            }
            return row
        }
        return try JSONEncoder().encode(File(version: 1, date: date, names: names, landmarks: rows))
    }
}

// MARK: - Building from OpenStreetMap

extension LandmarkBundle {
    /// An OpenStreetMap way as Overpass returns it with `out tags geom`.
    public struct Way: Sendable {
        public let tags: [String: String]
        public let nodes: [Coordinate]

        public init(tags: [String: String], nodes: [Coordinate]) {
            self.tags = tags
            self.nodes = nodes
        }

        func has(_ key: String) -> Bool { tags[key].map { $0 != "no" } ?? false }
    }

    /// Tunnels shorter than this are over before the line could be read; in meters.
    static let shortestTunnel = 200.0
    static let shortestBridge = 100.0
    /// A named bridge longer than this is shown without the river under it; in meters.
    static let longestRiverBridge = 1000.0

    /// The Overpass query for one tile (`south,west,north,east`): main-line tunnels with a name, main-line bridges
    /// with a name or over a named river plus the bridge ways touching those, the rivers, and every track beside
    /// any of them, to tell which ones a train on a neighboring track could be mistaken for. `landmarks(from:)`
    /// checks that a river within reach really is crossed.
    public static func query(box: String) -> String {
        """
        [out:json][timeout:170];
        way(\(box))[railway=rail][usage=main][tunnel]["tunnel:name"]->.t;
        way(\(box))[railway=rail][usage=main][bridge]->.b;
        way[waterway=river][name](around.b:15)->.r;
        way.b(around.r:15)->.x;
        (way.b["bridge:name"]; .x; way.b(around.x:1);)->.s;
        (.t; .s;)->.ts;
        (.ts; .r; way[railway=rail](around.ts:40);); out tags geom qt;
        .b out count;
        way.b(around.b:1); out count;
        """
    }

    /// Whether the server that answered `query(box:)` can search around ways at all: some public ones return
    /// nothing for that, without an error, which would lose every river and every track alongside. The query
    /// ends with a count of the bridges and of the bridges within a meter of a bridge, which must agree.
    public static func searchedAround(_ data: Data) -> Bool {
        struct Response: Decodable { let elements: [Element] }
        struct Element: Decodable { let type: String; let tags: [String: String]? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return false }
        let counts = response.elements.filter { $0.type == "count" }.map { $0.tags?["ways"] }
        return counts.count == 2 && counts[0] != nil && counts[0] == counts[1]
    }

    /// Ways by OpenStreetMap ID, so neighboring tiles can be merged.
    public static func parseWays(_ data: Data) throws -> [Int: Way] {
        struct Response: Decodable { let elements: [Element]; let remark: String? }
        struct Element: Decodable {
            let id: Int
            let tags: [String: String]?
            let geometry: [Node?]?
        }
        struct Node: Decodable { let lat: Double; let lon: Double }

        let response = try JSONDecoder().decode(Response.self, from: data)
        // An overloaded server answers 200 with a "runtime error" remark and only part of the elements.
        if let remark = response.remark, remark.contains("error") { throw OverpassClient.OverpassError.overloaded(remark) }
        var ways: [Int: Way] = [:]
        for element in response.elements {
            let nodes = (element.geometry ?? []).compactMap { $0.map { Coordinate(latitude: $0.lat, longitude: $0.lon) } }
            if let tags = element.tags, nodes.count > 1 { ways[element.id] = Way(tags: tags, nodes: nodes) }
        }
        return ways
    }

    /// The landmarks among `ways` (the answer to `query(box:)`, in a stable order). Left out, rather than risk a
    /// wrong name: tunnels and bridges too short to read, and stretches where another track runs alongside
    /// outside the tunnel or off the bridge, since position alone can't tell the two tracks apart.
    public static func landmarks(from ways: [Way]) -> [Landmark] {
        let rails = ways.filter { $0.tags["railway"] == "rail" }
        let rivers = ways.filter { $0.tags["waterway"] == "river" && $0.tags["name"] != nil }
        let tunnels = rails.filter { $0.tags["usage"] == "main" && $0.has("tunnel") && $0.tags["tunnel:name"] != nil }
        let bridges = rails.filter { $0.tags["usage"] == "main" && $0.has("bridge") }

        var found: [Landmark] = []
        for component in components(of: tunnels, key: "tunnel:name") where component.length >= shortestTunnel {
            let length = Int((component.length / 10).rounded()) * 10
            found += component.ways.map { Landmark(kind: .tunnel, name: $0.tags["tunnel:name"], length: length, nodes: $0.nodes) }
        }
        // By grid cell: tens of thousands of bridges against as many rivers is too much to compare one by one.
        func grid<T>(_ items: [T], nodes: (T) -> [Coordinate]) -> [GridCell: [T]] {
            var grid: [GridCell: [T]] = [:]
            for item in items {
                for cell in GridCell.cells(along: nodes(item)) { grid[cell, default: []].append(item) }
            }
            return grid
        }
        let riversAt = grid(rivers, nodes: \.nodes)
        let namedAt = grid(bridges.filter { $0.tags["bridge:name"] != nil }
            .map { Landmark(kind: .bridge, name: $0.tags["bridge:name"], nodes: $0.nodes) }, nodes: \.nodes)
        for component in components(of: bridges, key: "bridge:name") where component.length >= shortestBridge {
            // One track's way sometimes lacks the name its neighbor on the same bridge has.
            let name = component.ways[0].tags["bridge:name"] ?? component.ways.lazy.compactMap { way -> String? in
                let middle = way.nodes[way.nodes.count / 2]
                return namedAt[GridCell(middle)]?.first { $0.distance(at: middle, beside: 30, beyondEnd: 0) != nil }?.name
            }.first
            // A long viaduct crosses its river in one place; naming it for kilometers would say too much.
            let river = name != nil && component.length > longestRiverBridge ? nil : component.ways.lazy.compactMap { way -> String? in
                // Lines that cross share the cell they cross in.
                GridCell.cells(along: way.nodes).lazy.compactMap { cell in
                    riversAt[cell]?.first { crosses(way.nodes, $0.nodes) }?.tags["name"]
                }.first
            }.first
            guard name != nil || river != nil else { continue }
            found += component.ways.map { Landmark(kind: .bridge, name: name, river: river, nodes: $0.nodes) }
        }

        // Tracks outside a tunnel, or off a bridge, by grid cell.
        func index(without key: String) -> [GridCell: [Landmark]] {
            var grid: [GridCell: [Landmark]] = [:]
            for way in rails where !way.has(key) {
                let track = Landmark(kind: .tunnel, name: nil, nodes: way.nodes)
                for cell in GridCell.cells(along: way.nodes) { grid[cell, default: []].append(track) }
            }
            return grid
        }
        let outside = [Landmark.Kind.tunnel: index(without: "tunnel"), .bridge: index(without: "bridge")]
        return found.filter { landmark in
            let route = Route(points: landmark.nodes)
            let samples = stride(from: 0, through: route.length, by: 25).compactMap { route.coordinate(at: $0) }
            // Alongside, not ahead: the track leading up to the portal ends where this one starts.
            let ambiguous = samples.count { point in
                GridCell(point).neighbors.contains { cell in
                    outside[landmark.kind]?[cell]?.contains { $0.distance(at: point, beyondEnd: 0) != nil } ?? false
                }
            }
            return Double(ambiguous) < Double(samples.count) * 0.3
        }
        .map { Landmark(kind: $0.kind, name: $0.name, river: $0.river, length: $0.length,
                        nodes: TrackLimit(maxspeed: 0, nodes: $0.nodes).simplified(tolerance: 3).nodes) }
    }

    /// Ways with the same value for `key` that join end to end, and the length of the longest run through them:
    /// a tunnel is usually mapped in several pieces, and its second track as ways of its own.
    private static func components(of ways: [Way], key: String) -> [(ways: [Way], length: Double)] {
        struct End: Hashable { let name: String?; let lat: Int; let lon: Int }
        func end(_ way: Way, _ node: Coordinate) -> End {
            End(name: way.tags[key], lat: Int((node.latitude * 1e7).rounded()), lon: Int((node.longitude * 1e7).rounded()))
        }
        var edges: [End: [(to: End, way: Int, length: Double)]] = [:]
        for (index, way) in ways.enumerated() {
            let (a, b) = (end(way, way.nodes[0]), end(way, way.nodes[way.nodes.count - 1]))
            let length = Landmark(kind: .tunnel, name: nil, nodes: way.nodes).meters
            edges[a, default: []].append((b, index, length))
            edges[b, default: []].append((a, index, length))
        }
        /// The end farthest from `start` along the ways, and every way reached.
        func farthest(from start: End) -> (end: End, length: Double, ways: Set<Int>) {
            var best = (end: start, length: 0.0)
            var seen: Set<End> = [start]
            var reached = Set<Int>()
            var stack = [(start, 0.0)]
            while let (at, length) = stack.popLast() {
                if length > best.length { best = (at, length) }
                for edge in edges[at] ?? [] {
                    reached.insert(edge.way)
                    if seen.insert(edge.to).inserted { stack.append((edge.to, length + edge.length)) }
                }
            }
            return (best.end, best.length, reached)
        }
        var done = Set<Int>()
        var components: [(ways: [Way], length: Double)] = []
        for (index, way) in ways.enumerated() where !done.contains(index) {
            let first = farthest(from: end(way, way.nodes[0]))
            done.formUnion(first.ways)
            components.append((first.ways.sorted().map { ways[$0] }, farthest(from: first.end).length))
        }
        return components
    }

    /// Whether two lines cross.
    private static func crosses(_ a: [Coordinate], _ b: [Coordinate]) -> Bool {
        func box(_ nodes: [Coordinate]) -> (south: Double, north: Double, west: Double, east: Double) {
            (nodes.map(\.latitude).min() ?? 0, nodes.map(\.latitude).max() ?? 0, nodes.map(\.longitude).min() ?? 0, nodes.map(\.longitude).max() ?? 0)
        }
        let (p, q) = (box(a), box(b))
        guard p.south <= q.north, q.south <= p.north, p.west <= q.east, q.west <= p.east else { return false }
        func side(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate) -> Double {
            (b.longitude - a.longitude) * (c.latitude - a.latitude) - (b.latitude - a.latitude) * (c.longitude - a.longitude)
        }
        for (a1, a2) in zip(a, a.dropFirst()) {
            for (b1, b2) in zip(b, b.dropFirst())
            where side(a1, a2, b1) * side(a1, a2, b2) <= 0 && side(b1, b2, a1) * side(b1, b2, a2) <= 0 {
                return true
            }
        }
        return false
    }
}
