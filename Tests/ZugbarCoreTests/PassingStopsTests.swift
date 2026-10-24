import Foundation
import Testing
@testable import ZugbarCore

struct PassingStopsTests {
    let t0 = utc("2026-06-12T16:00:00Z")
    /// `km` north of a made-up origin.
    func point(_ km: Double) -> Coordinate { Coordinate(latitude: 50 + km / 111.2, longitude: 8) }
    var route: Route { Route(points: [point(0), point(20)]) }

    /// A at 0 km, B at 5, C at 10 and D at 20; the timetable has passed the first `passed` of them.
    func status(passed: Int, coordinates: Bool = true) -> TrainStatus {
        let stops = [("a", 0.0), ("b", 5), ("c", 10), ("d", 20)].enumerated().map { index, stop in
            Stop(id: stop.0, name: stop.0.uppercased(), scheduledArrival: t0.addingTimeInterval(Double(index) * 300),
                 passed: index < passed, coordinate: coordinates || stop.0 != "c" ? point(stop.1) : nil)
        }
        return TrainStatus(provider: "Transitous", trainName: "RE 1", stops: stops, nextStopID: stops[passed].id)
    }

    @Test func lateTrainHasNotPassedWhatTheTimetableSays() {
        // The times put it past B and C; the GPS has it 3 km out of A.
        let updated = status(passed: 3).passingStops(at: 3_000, on: route)
        #expect(updated.stops.map(\.passed) == [true, false, false, false])
        #expect(updated.nextStopID == "b")
    }

    @Test func standingAtThePlatformIsNotPast() {
        #expect(status(passed: 3).passingStops(at: 5_150, on: route).nextStopID == "b")
        #expect(status(passed: 1).passingStops(at: 5_600, on: route).nextStopID == "c")
    }

    @Test func earlyTrainHasPassedWhatTheTimetableHasNot() {
        let updated = status(passed: 1).passingStops(at: 11_000, on: route)
        #expect(updated.stops.map(\.passed) == [true, true, true, false])
        #expect(updated.nextStopID == "d")
    }

    @Test func stopsWithoutACoordinateGoWithTheirNeighbors() {
        // C has no coordinate: not passed while B isn't, passed once D is.
        #expect(status(passed: 3, coordinates: false).passingStops(at: 3_000, on: route).stops.map(\.passed)
            == [true, false, false, false])
        #expect(status(passed: 1, coordinates: false).passingStops(at: 20_500, on: route).stops.map(\.passed)
            == [true, true, true, true])
    }

    @Test func cancelledStopsAreNotNext() {
        var status = status(passed: 1)
        status.stops[1].cancelled = true
        #expect(status.passingStops(at: 1_000, on: route).nextStopID == "c")
    }
}

struct PassingStopsReversalTests {
    func point(_ km: Double) -> Coordinate { Coordinate(latitude: 50 + km / 111.2, longitude: 8) }

    /// Out to K at 10 km and back the same way: A, P at 5 km, K, then P again on the way back.
    func status() -> TrainStatus {
        let stops = [("a", 0.0), ("p", 5), ("k", 10), ("q", 5)].map { Stop(id: $0.0, name: $0.0, coordinate: point($0.1)) }
        return TrainStatus(provider: "Transitous", trainName: "RE 1", stops: stops, nextStopID: "p")
    }

    @Test func aStationOnTheWayBackGetsItsOwnVisit() {
        let route = Route(points: [point(0), point(10), point(0)])
        #expect(abs(route.along(of: point(5), from: 0) - 5_000) < 10)
        #expect(abs(route.along(of: point(5), from: 10_000) - 15_000) < 10)
        // 2 km back from K: P passed on the way out, its second visit still ahead.
        let back = status().passingStops(at: 12_000, on: route)
        #expect(back.stops.map(\.passed) == [true, true, true, false])
        #expect(back.nextStopID == "q")
        #expect(status().passingStops(at: 3_000, on: route).nextStopID == "p")
    }
}
