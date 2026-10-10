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

    /// Online data is polled every 30 s, so `passed` lags behind the clock. Passing a stop must not make the
    /// train wait there until the next poll and then jump (#10).
    @Test func movesOnFromAStopBeforeTheNextPoll() throws {
        let start = utc("2026-06-12T16:00:00Z")
        let route = Route(points: [Coordinate(latitude: 50, longitude: 8), Coordinate(latitude: 50, longitude: 9), Coordinate(latitude: 50, longitude: 10)])
        // Fetched at 16:00: B (16:30–16:32) not passed yet. B's coordinate is 300 m off the track.
        let stops = [
            Stop(id: "a", name: "A", scheduledDeparture: start, passed: true, coordinate: Coordinate(latitude: 50, longitude: 8)),
            Stop(id: "b", name: "B", scheduledArrival: start.addingTimeInterval(1800), scheduledDeparture: start.addingTimeInterval(1920),
                 coordinate: Coordinate(latitude: 50.003, longitude: 9)),
            Stop(id: "c", name: "C", scheduledArrival: start.addingTimeInterval(3720), coordinate: Coordinate(latitude: 50, longitude: 10)),
        ]
        let status = TrainStatus(provider: "Transitous", stops: stops, route: route)

        // Standing at B: on the track, not at the station's coordinate.
        let atStop = try #require(status.position(at: start.addingTimeInterval(1860)))
        #expect(abs(atStop.latitude - 50) < 0.0001)
        #expect(status.estimatedSpeed(at: start.addingTimeInterval(1860)) == 0)

        // 20 s after leaving B, still before the next poll: already in the next section and moving.
        let after = start.addingTimeInterval(1940)
        #expect(status.routeEstimate(at: after)?.previousStopID == "b")
        #expect(try #require(status.estimatedSpeed(at: after)) > 0)
        let moved = try #require(status.position(at: after))
        #expect(moved.longitude > 9 && moved.longitude < 9.02)
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

    @Test func neverFasterThanTheLimit() throws {
        // RE70 Biebesheim → Stockstadt: ~5.5 km in a minute-rounded "3 min" is tighter than a regional train can do.
        let profile = try #require(SpeedProfile(length: 5_500, limits: Array(repeating: 160, count: 56), duration: 180, kind: .regional))
        let peak = stride(from: 0.0, through: 400, by: 2).map { profile.state(after: $0).speed }.max() ?? 0
        #expect(peak <= 160)
    }

    @Test func trainKinds() {
        #expect(TrainKind.of("ICE 591") == .highSpeed)
        #expect(TrainKind.of("IC 2023") == .intercity)
        #expect(TrainKind.of("RE70 (4589)") == .regional)
        #expect(TrainKind.of("S5") == .suburban)
        #expect(TrainKind.of(nil) == .regional)
    }

    @Test func regionalEstimateStaysRealistic() {
        let start = utc("2026-06-12T16:00:00Z")
        let route = Route(points: [Coordinate(latitude: 49.80, longitude: 8.46), Coordinate(latitude: 49.85, longitude: 8.45)])
        let stops = [
            Stop(id: "a", name: "Biebesheim", scheduledDeparture: start, passed: true, coordinate: route.points[0]),
            Stop(id: "b", name: "Stockstadt", scheduledArrival: start.addingTimeInterval(180), coordinate: route.points[1]),
        ]
        let status = TrainStatus(provider: "Transitous", trainName: "RE70 (4589)", stops: stops, route: route)
        let speeds = stride(from: 5.0, through: 175, by: 5).compactMap { status.estimatedSpeed(at: start.addingTimeInterval($0)) }
        #expect(!speeds.isEmpty)
        #expect(speeds.allSatisfy { $0 <= 160 })
        #expect(status.isOnline)
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
            if url == OverpassClient.endpoints[0] { throw URLError(.timedOut) }
            return try fixture("overpass_tracks")
        }
        let points = [Coordinate(latitude: 50, longitude: 8), Coordinate(latitude: 50.1, longitude: 8.1)]
        #expect(try await !client.tracks(along: points).isEmpty)
        #expect(await counter.value == 2)
        // The server that answered is asked first next time.
        #expect(try await !client.tracks(along: points).isEmpty)
        #expect(await counter.value == 3)
    }

    @Test func overpassDownEverywhereIsUnreachable() async {
        let client = OverpassClient { _, _ in throw URLError(.timedOut) }
        let points = [Coordinate(latitude: 50, longitude: 8), Coordinate(latitude: 50.1, longitude: 8.1)]
        await #expect(throws: OverpassClient.OverpassError.unreachable) { try await client.tracks(along: points) }
    }
}

struct SignallingTests {
    @Test func pzbOnlyLinesStayAt160() {
        #expect(OverpassClient.signalledSpeed(200, tags: ["railway:pzb": "yes"]) == 160)
        #expect(OverpassClient.signalledSpeed(200, tags: ["railway:pzb": "yes", "railway:lzb": "no"]) == 160)
        #expect(OverpassClient.signalledSpeed(200, tags: ["railway:pzb": "yes", "railway:lzb": "yes"]) == 200)
        #expect(OverpassClient.signalledSpeed(300, tags: ["railway:pzb": "yes", "railway:etcs": "2"]) == 300)
        // Outside PZB networks (e.g. French LGVs) the tagged speed stands.
        #expect(OverpassClient.signalledSpeed(320, tags: ["railway:tvm": "430"]) == 320)
        #expect(OverpassClient.signalledSpeed(120, tags: ["railway:pzb": "yes"]) == 120)
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
