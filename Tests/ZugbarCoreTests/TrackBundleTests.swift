import Foundation
import Testing
@testable import ZugbarCore

struct TrackBundleTests {
    /// A straight line north with nodes only at its ends, like a high-speed line in OpenStreetMap.
    let line = TrackLimit(maxspeed: 280, nodes: [Coordinate(latitude: 50, longitude: 9), Coordinate(latitude: 50.2, longitude: 9)])

    @Test func distanceToTheLineNotItsNodes() {
        let middle = Coordinate(latitude: 50.1, longitude: 9.0002) // ~14 m beside, 11 km from either node
        #expect(line.distance(to: middle) < 0.02)
        #expect(line.distance(to: Coordinate(latitude: 50.1, longitude: 9.01)) > 0.7)
        let limits = SpeedProfile.limits(along: [Coordinate(latitude: 50.05, longitude: 9), Coordinate(latitude: 50.15, longitude: 9)], samples: 10, tracks: [line])
        #expect(limits == Array(repeating: 280, count: 10))
    }

    @Test func simplifiesStraightTrack() {
        let dense = TrackLimit(maxspeed: 160, nodes: (0...100).map { Coordinate(latitude: 50 + Double($0) * 0.001, longitude: 9) })
        #expect(dense.simplified(tolerance: 3).nodes.count == 2)
        // A bend more than 3 m off the line stays.
        var nodes = dense.nodes
        nodes[50] = Coordinate(latitude: nodes[50].latitude, longitude: 9.001)
        #expect(TrackLimit(maxspeed: 160, nodes: nodes).simplified(tolerance: 3).nodes.count == 5)
    }

    @Test func roundTrip() throws {
        let bundle = TrackBundle(date: "2026-06-12", tracks: [line, TrackLimit(maxspeed: 120, nodes: [Coordinate(latitude: 48.5, longitude: 11.25), Coordinate(latitude: 48.50001, longitude: 11.3)])])
        let decoded = try TrackBundle(compressed: bundle.compressed())
        #expect(decoded.date == "2026-06-12")
        #expect(decoded.tracks.map(\.maxspeed) == [280, 120])
        #expect(abs(decoded.tracks[1].nodes[1].latitude - 48.50001) < 1e-9)
        #expect(abs(decoded.tracks[1].nodes[1].longitude - 11.3) < 1e-9)
    }

    @Test func onlyUsedWhereItCoversTheSection() {
        let bundle = TrackBundle(date: "", tracks: [line])
        let onLine = [Coordinate(latitude: 50.02, longitude: 9), Coordinate(latitude: 50.18, longitude: 9)]
        #expect(bundle.tracks(along: onLine)?.count == 1)
        // The last third leaves the bundled line: a branch line Overpass should answer for.
        let leaving = onLine + [Coordinate(latitude: 50.18, longitude: 9.15)]
        #expect(bundle.tracks(along: leaving) == nil)
    }
}
