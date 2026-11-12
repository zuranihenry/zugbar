import Foundation
import Testing
@testable import ZugbarCore

struct TripPathTests {
    let start = utc("2026-06-12T16:00:00Z")
    /// About 111 m of latitude.
    let step = 0.001

    func onBoard(latitude: Double, longitude: Double = 8) -> TrainStatus {
        let stops = [
            Stop(id: "a", name: "A", passed: true, coordinate: Coordinate(latitude: 50, longitude: 8)),
            Stop(id: "b", name: "B", coordinate: Coordinate(latitude: 51, longitude: 8)),
        ]
        return TrainStatus(provider: "ICE Portal", trainName: "ICE 1", speed: 120, stops: stops,
                           position: Coordinate(latitude: latitude, longitude: longitude))
    }

    func line(from: Double, to: Double, longitude: Double = 8) -> [Coordinate] {
        stride(from: from, through: to, by: 0.005).map { Coordinate(latitude: $0, longitude: longitude) }
    }

    @Test func loadsATripLogFromBeforePathsWereKept() throws {
        let old = """
        {"trips":[
          {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","train":"ICE 1","from":"A","to":"B","start":800000000,"end":800003600,
           "distance":123.4,"topSpeed":250,"arrivalDelay":3,"samples":[{"t":0,"km":0,"kmh":80,"delay":2},{"t":30,"km":0.9}]},
          {"id":"6F9619FF-8B86-D011-B42D-00C04FC964F0","train":"RE 2","from":"B","to":"C","start":700000000,"end":700001800,
           "distance":40,"topSpeed":140}
        ]}
        """
        var log = try JSONDecoder().decode(TripLog.self, from: Data(old.utf8))
        #expect(log.trips.map(\.train) == ["ICE 1", "RE 2"])
        #expect(log.trips[0].samples?.count == 2)
        #expect(log.trips.allSatisfy { $0.path == nil })
        #expect(TravelledNetwork(trips: log.trips).isEmpty)

        // A new trip next to the old ones survives saving and loading, to the meter.
        let path = TripPath(lines: [line(from: 50, to: 50.5), line(from: 50.6, to: 50.7)])
        log.add(Trip(train: "ICE 3", from: "C", to: "D", start: start, end: start.addingTimeInterval(3600), distance: 60,
                     topSpeed: 200, path: path))
        let saved = try JSONEncoder().encode(log)
        let loaded = try JSONDecoder().decode(TripLog.self, from: saved)
        #expect(loaded.trips.count == 3)
        let lines = try #require(loaded.trips[0].path?.lines)
        #expect(lines.map(\.count) == path.lines.map(\.count))
        #expect(lines[1][0].distance(to: path.lines[1][0]) < 0.002)
        #expect(loaded.trips[1].path == nil)
    }

    @Test func encodesPolylinesBothWays() {
        let points = [Coordinate(latitude: 38.5, longitude: -120.2), Coordinate(latitude: 40.7, longitude: -120.95),
                      Coordinate(latitude: 43.252, longitude: -126.453)]
        #expect(Route.encode(points) == "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(Route.decode(Route.encode(points)) == points)
        #expect(Route.encode([]) == "")
    }

    @Test func recordsThePathOfATrip() throws {
        var recorder = TripRecorder()
        for second in stride(from: 0.0, through: 600, by: 3) {
            _ = recorder.update(onBoard(latitude: 50 + second / 3 * step / 3), at: start.addingTimeInterval(second))
        }
        let finished = recorder.finish()
        let lines = try #require(finished?.path?.lines)
        #expect(lines.count == 1)
        #expect(lines[0].first == Coordinate(latitude: 50, longitude: 8))
        #expect(abs(lines[0].last!.latitude - (50 + 200 * step / 3)) < 1e-9)
        // 7.4 km with a point every 200 m.
        #expect((30...40).contains(lines[0].count))
    }

    @Test func breaksTheLineAtAGapAndDropsABadFix() throws {
        var sampler = PathSampler()
        for index in 0...50 { sampler.record(Coordinate(latitude: 50 + Double(index) * step, longitude: 8)) }
        // One fix 10 km off, as after a tunnel.
        sampler.record(Coordinate(latitude: 50.14, longitude: 8))
        for index in 51...100 { sampler.record(Coordinate(latitude: 50 + Double(index) * step, longitude: 8)) }
        // No fixes for 20 km.
        for index in 300...350 { sampler.record(Coordinate(latitude: 50 + Double(index) * step, longitude: 8)) }
        let lines = try #require(sampler.path?.lines)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { line in line.allSatisfy { $0.latitude < 50.36 && $0.latitude != 50.14 } })
        #expect(abs(lines[0].last!.latitude - 50.05) < 1e-9)
        #expect(abs(lines[1].first!.latitude - 50.051) < 1e-9)
        #expect(abs(lines[2].first!.latitude - 50.3) < 1e-9)
        // Nothing drawn across the gap.
        #expect(lines.allSatisfy { line in zip(line, line.dropFirst()).allSatisfy { $0.distance(to: $1) < 1 } })
    }

    @Test func hasNoPathBeforeTheTrainMoved() {
        var sampler = PathSampler()
        #expect(sampler.path == nil)
        sampler.record(Coordinate(latitude: 50, longitude: 8))
        sampler.record(Coordinate(latitude: 50, longitude: 8))
        #expect(sampler.path == nil)
    }

    @Test func keepsLongTripsSmall() throws {
        var sampler = PathSampler()
        // 1100 km, a fix every 111 m.
        for index in 0...10_000 { sampler.record(Coordinate(latitude: 45 + Double(index) * step, longitude: 8)) }
        let path = try #require(sampler.path)
        #expect(path.lines.count == 1)
        #expect(path.lines[0].count <= 401)
        #expect(path.lines[0].count > 150)
        #expect(path.lines[0].first?.latitude == 45)
        #expect(abs(path.lines[0].last!.latitude - 55) < 1e-9)
        let stored = try JSONEncoder().encode(path)
        #expect(stored.count < 2500)
    }

    @Test func drawsStretchesRiddenMoreOftenStronger() {
        func trip(_ lines: [[Coordinate]]) -> Trip {
            Trip(train: "ICE 1", from: "A", to: "B", start: start, end: start, distance: 0, topSpeed: 0, path: TripPath(lines: lines))
        }
        // Once all the way, twice more over the middle on slightly different fixes, and five times on a branch.
        let whole = trip([line(from: 50, to: 51)])
        let middle = (1...2).map { trip([line(from: 50.4012, to: 50.6, longitude: 8 + 0.0005 * Double($0))]) }
        let branch = (1...5).map { _ in trip([line(from: 50, to: 50.2, longitude: 9)]) }
        let unknown = Trip(train: "RE 2", from: "B", to: "C", start: start, end: start, distance: 40, topSpeed: 140)
        let network = TravelledNetwork(trips: [whole] + middle + branch + [unknown])
        #expect(network.tripCount == 8)

        func covers(_ strength: Int, latitude: Double, longitude: Double) -> Bool {
            network.lines[strength].contains { line in
                zip(line, line.dropFirst()).contains { from, to in
                    abs(from.longitude - longitude) < 0.01 && min(from.latitude, to.latitude) <= latitude
                        && latitude <= max(from.latitude, to.latitude)
                }
            }
        }
        #expect(covers(0, latitude: 50.2, longitude: 8))
        #expect(!covers(1, latitude: 50.2, longitude: 8))
        #expect(covers(1, latitude: 50.5, longitude: 8))
        #expect(covers(0, latitude: 50.8, longitude: 8))
        #expect(covers(2, latitude: 50.1, longitude: 9))
        #expect(!covers(0, latitude: 50.1, longitude: 9))
        #expect(!covers(1, latitude: 50.1, longitude: 9))
        // Every piece of every path is drawn exactly once.
        let drawn = network.lines.flatMap { $0 }.reduce(0) { $0 + $1.count - 1 }
        let ridden = ([whole] + middle + branch).flatMap { $0.path!.lines }.reduce(0) { $0 + $1.count - 1 }
        #expect(drawn == ridden)
    }
}
