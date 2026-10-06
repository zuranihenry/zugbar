import Foundation
import Testing
@testable import ZugbarCore

struct RouteTests {
    @Test func decodesGooglePolyline() {
        let points = Route.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5)
        #expect(points.count == 3)
        #expect(abs(points[0].latitude - 38.5) < 1e-6 && abs(points[0].longitude + 120.2) < 1e-6)
        #expect(abs(points[2].latitude - 43.252) < 1e-6 && abs(points[2].longitude + 126.453) < 1e-6)
    }

    @Test func measuresAlongTheRoute() {
        let route = Route(points: [Coordinate(latitude: 50, longitude: 8), Coordinate(latitude: 50, longitude: 9), Coordinate(latitude: 51, longitude: 9)])
        #expect(abs(route.length - (71_500 + 111_200)) < 1_500)
        let middle = route.coordinate(at: route.distances[1] / 2)
        #expect(middle.map { abs($0.longitude - 8.5) < 0.01 } == true)
        #expect(abs(route.distance(of: Coordinate(latitude: 51.01, longitude: 9)) - route.length) < 1)
    }

    @Test func positionFollowsTrack() {
        let start = utc("2026-06-12T16:00:00Z")
        // An L-shaped route: the straight line between the stops would cut the corner.
        let route = Route(points: [Coordinate(latitude: 50, longitude: 8), Coordinate(latitude: 50, longitude: 9), Coordinate(latitude: 51, longitude: 9)])
        let stops = [
            Stop(id: "a", name: "A", scheduledDeparture: start, passed: true, coordinate: Coordinate(latitude: 50, longitude: 8)),
            Stop(id: "b", name: "B", scheduledArrival: start.addingTimeInterval(3600), coordinate: Coordinate(latitude: 51, longitude: 9)),
        ]
        let status = TrainStatus(provider: "Transitous", stops: stops, route: route)
        let estimate = status.routeEstimate(at: start.addingTimeInterval(600))
        #expect(estimate.map { (170...190).contains($0.averageSpeed) } == true)
        // Just after departure the train is still accelerating, not at its average speed.
        let early = status.estimatedSpeed(at: start.addingTimeInterval(20))
        #expect(early.map { $0 < 60 } == true)
        // About 40% of the way the train is still on the east-west leg.
        let position = status.position(at: start.addingTimeInterval(0.35 * 3600))
        #expect(position.map { abs($0.latitude - 50) < 0.01 } == true)
    }
}

struct SpeedProfileTests {
    @Test func matchesTimetable() throws {
        // 60 km in 30 min at up to 200 km/h: the train has to average 120 km/h.
        let profile = try #require(SpeedProfile(length: 60_000, limits: Array(repeating: 200, count: 601), duration: 1800))
        #expect(profile.state(after: 0).speed == 0)
        let end = profile.state(after: 1800)
        #expect(end.speed < 5 && abs(end.distance - 60_000) < 200)
        let cruise = profile.state(after: 900).speed
        #expect((110...200).contains(cruise))
    }

    @Test func slowsDownForLowLimits() throws {
        // First half 250 km/h, second half 80 km/h.
        let limits = Array(repeating: 250, count: 301) + Array(repeating: 80, count: 300)
        let profile = try #require(SpeedProfile(length: 60_000, limits: limits, duration: 2100))
        let fastPart = profile.state(after: 300).speed
        let slowPart = profile.state(after: 1500).speed
        #expect(fastPart > slowPart)
        #expect(slowPart <= 85)
    }

    @Test func limitsFromOpenStreetMap() throws {
        let tracks = try OverpassClient.parse(fixture("overpass_tracks"))
        #expect(!tracks.isEmpty)
        #expect(tracks[0].maxspeed == 200) // "200;160"
        struct Section: Decodable { let points: [[Double]] }
        let section = try JSONDecoder().decode(Section.self, from: fixture("route_section"))
        let points = section.points.map { Coordinate(latitude: $0[0], longitude: $0[1]) }
        let limits = SpeedProfile.limits(along: points, samples: 50, tracks: tracks)
        #expect(limits.count == 50)
        #expect(limits.allSatisfy { (30...300).contains($0) })
        #expect(Set(limits).count > 1)
    }

    @Test func overpassFallsBackToSecondServer() async throws {
        let counter = Counter()
        let client = OverpassClient { url, _ in
            await counter.increment()
            if url.host == "overpass-api.de" { throw URLError(.timedOut) }
            return try fixture("overpass_tracks")
        }
        let tracks = try await client.tracks(along: [Coordinate(latitude: 50, longitude: 8), Coordinate(latitude: 50.1, longitude: 8.1)])
        #expect(!tracks.isEmpty)
        #expect(await counter.value == 2)
    }
}

struct OverpassErrorTests {
    @Test func overloadedServerCountsAsFailure() {
        let json = Data(#"{"elements":[],"remark":"runtime error: Query timed out in \"query\" at line 1 after 26 seconds."}"#.utf8)
        #expect(throws: (any Error).self) { try OverpassClient.parse(json) }
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
