import Foundation
import Testing
@testable import ZugbarCore

struct LandmarkTests {
    /// A point `north` and `east` meters from a made-up origin.
    static func at(_ north: Double, east: Double = 0) -> Coordinate {
        Coordinate(latitude: 50 + north / 111_200, longitude: 9 + east / (111_200 * cos(50 * .pi / 180)))
    }

    /// A tunnel running north from 1000 m to 3000 m, with a bend in the middle.
    let tunnel = Landmark(kind: .tunnel, name: "Musterbergtunnel", length: 2000,
                          nodes: [at(1000), at(2000, east: 20), at(3000)])
    var bundle: LandmarkBundle { LandmarkBundle(date: "", landmarks: [tunnel]) }

    @Test func insideTheTunnel() {
        #expect(bundle.landmark(at: Self.at(1001)) == tunnel)
        #expect(bundle.landmark(at: Self.at(2000, east: 20)) == tunnel)
        #expect(bundle.landmark(at: Self.at(2999)) == tunnel)
    }

    @Test func notJustBeforeOrAfter() {
        #expect(bundle.landmark(at: Self.at(970)) == nil)
        #expect(bundle.landmark(at: Self.at(3030)) == nil)
        // A few meters short of the mapped portal is within what GPS and mapping can tell apart.
        #expect(bundle.landmark(at: Self.at(990)) == tunnel)
        #expect(bundle.landmark(at: Self.at(3010)) == tunnel)
    }

    @Test func gpsALittleOffTheTrack() {
        #expect(bundle.landmark(at: Self.at(1500, east: 35)) == tunnel)
        #expect(bundle.landmark(at: Self.at(1500, east: -20)) == tunnel)
        // Off to the side and short of the portal at once.
        #expect(bundle.landmark(at: Self.at(992, east: 25)) == tunnel)
        #expect(bundle.landmark(at: Self.at(970, east: 25)) == nil)
        // Too far off to be this track.
        #expect(bundle.landmark(at: Self.at(1500, east: 80)) == nil)
    }

    @Test func nothingWhereNothingIs() {
        #expect(bundle.landmark(at: Self.at(20_000)) == nil)
        #expect(bundle.landmark(at: Self.at(1500, east: 5000)) == nil)
        #expect(LandmarkBundle(date: "", landmarks: []).landmark(at: Self.at(1500)) == nil)
    }

    @Test func aLineCrossingOverIsNotInTheTunnel() {
        // Travelling along it in either direction, the heading agrees; crossing it at a right angle, it doesn't.
        #expect(bundle.landmark(at: Self.at(1500), heading: 2) == tunnel)
        #expect(bundle.landmark(at: Self.at(1500), heading: 185) == tunnel)
        #expect(bundle.landmark(at: Self.at(1500), heading: 90) == nil)
        #expect(bundle.landmark(at: Self.at(1500), heading: 300) == nil)
    }

    @Test func tunnelWinsOverABridgeAtTheSamePlace() {
        let bridge = Landmark(kind: .bridge, name: "Musterbrücke", river: "Musterbach", nodes: [Self.at(1400), Self.at(1600)])
        let both = LandmarkBundle(date: "", landmarks: [bridge, tunnel])
        #expect(both.landmark(at: Self.at(1500, east: 1)) == tunnel)
        #expect(LandmarkBundle(date: "", landmarks: [bridge]).landmark(at: Self.at(1500))?.river == "Musterbach")
    }

    @Test func roundTrip() throws {
        let bridge = Landmark(kind: .bridge, name: nil, river: "Musterbach", nodes: [Self.at(5000), Self.at(5200)])
        let named = Landmark(kind: .bridge, name: "Musterbrücke", nodes: [Self.at(7000), Self.at(7200)])
        let decoded = try LandmarkBundle(compressed: LandmarkBundle(date: "2026-01-01", landmarks: [tunnel, bridge, named]).compressed())
        #expect(decoded.date == "2026-01-01")
        #expect(decoded.landmarks.map(\.kind) == [.tunnel, .bridge, .bridge])
        #expect(decoded.landmarks.map(\.name) == ["Musterbergtunnel", nil, "Musterbrücke"])
        #expect(decoded.landmarks.map(\.river) == [nil, "Musterbach", nil])
        #expect(decoded.landmarks.map(\.length) == [2000, nil, nil])
        #expect(decoded.landmark(at: Self.at(5100))?.river == "Musterbach")
        #expect(decoded.landmark(at: Self.at(4960)) == nil)
    }

    // MARK: Building

    static func rail(_ nodes: [Coordinate], _ tags: [String: String] = [:]) -> LandmarkBundle.Way {
        LandmarkBundle.Way(tags: ["railway": "rail", "usage": "main"].merging(tags) { $1 }, nodes: nodes)
    }

    static let inTunnel = ["tunnel": "yes", "tunnel:name": "Musterbergtunnel"]

    @Test func tunnelLengthAcrossItsPieces() {
        // Two pieces end to end, and the second track as one way 8 m beside: 1200 m, not 2400 m.
        let ways = [
            Self.rail([Self.at(0), Self.at(500)], Self.inTunnel),
            Self.rail([Self.at(500), Self.at(1200)], Self.inTunnel),
            Self.rail([Self.at(0, east: 8), Self.at(1200, east: 8)], Self.inTunnel),
            // The line outside, leading up to and away from both portals.
            Self.rail([Self.at(-2000), Self.at(0)]),
            Self.rail([Self.at(1200), Self.at(3000)]),
        ]
        let landmarks = LandmarkBundle.landmarks(from: ways)
        #expect(landmarks.count == 3)
        #expect(landmarks.allSatisfy { $0.kind == .tunnel && $0.name == "Musterbergtunnel" && $0.length == 1200 })
    }

    @Test func leavesOutWhatIsTooShortToRead() {
        let short = Self.rail([Self.at(0), Self.at(150)], Self.inTunnel)
        let culvert = Self.rail([Self.at(0), Self.at(40)], ["bridge": "yes", "bridge:name": "Musterbrücke"])
        #expect(LandmarkBundle.landmarks(from: [short, culvert]).isEmpty)
    }

    @Test func leavesOutATunnelWithATrackAlongsideOutside() {
        // A station above its own tunnel: on the surface track, position alone would claim the tunnel.
        let tunnel = Self.rail([Self.at(0), Self.at(1000)], Self.inTunnel)
        let surface = Self.rail([Self.at(-200, east: 15), Self.at(1200, east: 15)])
        #expect(LandmarkBundle.landmarks(from: [tunnel, surface]).isEmpty)
        // Alongside for only a short way: kept.
        let passing = Self.rail([Self.at(-200, east: 15), Self.at(150, east: 15), Self.at(400, east: 400)])
        #expect(LandmarkBundle.landmarks(from: [tunnel, passing]).count == 1)
        // `tunnel=no` is no tunnel.
        let open = Self.rail([Self.at(0, east: 15), Self.at(1000, east: 15)], ["tunnel": "no"])
        #expect(LandmarkBundle.landmarks(from: [tunnel, open]).isEmpty)
    }

    @Test func bridgesByNameOrRiver() {
        let river = LandmarkBundle.Way(tags: ["waterway": "river", "name": "Musterbach"],
                                       nodes: [Self.at(150, east: -500), Self.at(150, east: 500)])
        let over = ["bridge": "yes"]
        let ways = [
            river,
            // Named, over the river.
            Self.rail([Self.at(0), Self.at(300)], ["bridge": "viaduct", "bridge:name": "Musterbrücke"]),
            // The same bridge's second track, without the name.
            Self.rail([Self.at(0, east: 8), Self.at(300, east: 8)], over),
            // Nameless over the river, far from the first.
            Self.rail([Self.at(0, east: 300), Self.at(300, east: 300)], over),
            // Named, over dry land.
            Self.rail([Self.at(2000), Self.at(2300)], over.merging(["bridge:name": "Mustertalbrücke"]) { $1 }),
            // Nameless over dry land: nothing to say.
            Self.rail([Self.at(4000), Self.at(4300)], over),
            // A long viaduct that happens to cross the river somewhere: its name only.
            Self.rail([Self.at(-1000, east: -300), Self.at(1500, east: -300)], over.merging(["bridge:name": "Musterviadukt"]) { $1 }),
        ]
        let landmarks = LandmarkBundle.landmarks(from: ways)
        #expect(landmarks.map(\.name) == ["Musterbrücke", "Musterbrücke", nil, "Mustertalbrücke", "Musterviadukt"])
        #expect(landmarks.map(\.river) == ["Musterbach", "Musterbach", "Musterbach", nil, nil])
        #expect(landmarks.allSatisfy { $0.kind == .bridge && $0.length == nil })
    }

    @Test func parsesOverpass() throws {
        let json = """
        {"elements": [
          {"type": "way", "id": 7, "tags": {"railway": "rail", "usage": "main", "tunnel": "yes", "tunnel:name": "Musterbergtunnel"},
           "geometry": [{"lat": 50.0, "lon": 9.0}, null, {"lat": 50.01, "lon": 9.0}]},
          {"type": "way", "id": 8, "tags": {"waterway": "river", "name": "Musterbach"}, "geometry": [{"lat": 50.0, "lon": 9.0}]}
        ]}
        """
        let ways = try LandmarkBundle.parseWays(Data(json.utf8))
        #expect(ways.keys.sorted() == [7])
        #expect(ways[7]?.nodes.count == 2)
        #expect(LandmarkBundle.landmarks(from: Array(ways.values)).first?.length == 1110)
        // A server that can't search around ways finds no bridge next to itself.
        func counts(_ all: Int, _ around: Int) -> Data {
            Data(#"{"elements": [{"type": "count", "id": 0, "tags": {"ways": "\#(all)"}}, {"type": "count", "id": 0, "tags": {"ways": "\#(around)"}}]}"#.utf8)
        }
        #expect(LandmarkBundle.searchedAround(counts(12, 12)))
        #expect(!LandmarkBundle.searchedAround(counts(12, 0)))
        #expect(!LandmarkBundle.searchedAround(Data(json.utf8)))
        #expect((try LandmarkBundle.parseWays(counts(12, 12))).isEmpty)
        #expect(throws: OverpassClient.OverpassError.self) {
            try LandmarkBundle.parseWays(Data(#"{"elements": [], "remark": "runtime error: timed out"}"#.utf8))
        }
    }
}
