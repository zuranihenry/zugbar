import Foundation
import Testing
@testable import ZugbarCore

struct TripLogTests {
    let start = utc("2026-06-12T16:00:00Z")
    let stops = [
        Stop(id: "a", name: "A", scheduledDeparture: utc("2026-06-12T15:58:00Z"), passed: true, coordinate: Coordinate(latitude: 50, longitude: 8)),
        Stop(id: "b", name: "B", scheduledArrival: utc("2026-06-12T16:30:00Z"), expectedArrival: utc("2026-06-12T16:33:00Z"),
             coordinate: Coordinate(latitude: 50.5, longitude: 8)),
    ]

    func onBoard(_ minute: Double, latitude: Double, speed: Int, train: String = "ICE 1") -> TrainStatus {
        TrainStatus(provider: "ICE Portal", trainName: train, speed: speed, stops: stops, position: Coordinate(latitude: latitude, longitude: 8))
    }

    @Test func recordsATripFromGPS() throws {
        var recorder = TripRecorder()
        for minute in stride(from: 0.0, through: 30, by: 1) {
            let finished = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: minute == 15 ? 250 : 120),
                                           at: start.addingTimeInterval(minute * 60))
            #expect(finished == nil)
        }
        let finished = recorder.finish()
        let trip = try #require(finished)
        #expect(trip.train == "ICE 1")
        #expect(trip.from == "A")
        #expect(trip.to == "B")
        #expect(abs(trip.distance - 55.6) < 0.5)
        #expect(trip.topSpeed == 250)
        #expect(trip.arrivalDelay == 3)
        #expect(trip.duration == 30 * 60)
        let again = recorder.finish()
        #expect(again == nil)
    }

    @Test func endsWhenAnotherTrainOrOnline() throws {
        var recorder = TripRecorder()
        for minute in stride(from: 0.0, through: 10, by: 1) {
            _ = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: 150), at: start.addingTimeInterval(minute * 60))
        }
        let next = recorder.update(onBoard(11, latitude: 50.2, speed: 100, train: "ICE 2"), at: start.addingTimeInterval(11 * 60))
        #expect(next?.train == "ICE 1")
        // Following a train online isn't riding it.
        let online = TrainStatus(provider: "Transitous", trainName: "ICE 2", stops: stops)
        let afterOnline = recorder.update(online, at: start.addingTimeInterval(12 * 60))
        #expect(afterOnline == nil) // ICE 2 only 1 min: too short
        let rest = recorder.finish()
        #expect(rest == nil)
    }

    @Test func ignoresGlimpsesAndJumps() {
        var recorder = TripRecorder()
        _ = recorder.update(onBoard(0, latitude: 50, speed: 0), at: start)
        // A fix 100 km away a minute later is a bad fix, not 6000 km/h.
        _ = recorder.update(onBoard(1, latitude: 50.9, speed: 0), at: start.addingTimeInterval(60))
        _ = recorder.update(onBoard(2, latitude: 50.9, speed: 0), at: start.addingTimeInterval(120))
        let trip = recorder.finish()
        #expect(trip == nil)
    }

    @Test func totalsAndCSV() {
        var log = TripLog()
        log.add(Trip(train: "ICE 1", from: "A", to: "B, Hbf", start: start, end: start.addingTimeInterval(1800), distance: 55.6, topSpeed: 250, arrivalDelay: 3))
        log.add(Trip(train: "RE 1", from: "B", to: "C", start: start.addingTimeInterval(3600), end: start.addingTimeInterval(5400), distance: 20, topSpeed: 140))
        #expect(log.trips.first?.train == "RE 1")
        #expect(abs(log.distance(inYearOf: start, calendar: Calendar(identifier: .gregorian)) - 75.6) < 0.01)
        #expect(log.fastest?.train == "ICE 1")
        let lines = log.csv().split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[2].hasPrefix("ICE 1,A,\"B, Hbf\",2026-06-12T16:00:00Z,"))
        #expect(lines[2].hasSuffix(",55.6,30,250,3"))
        log.remove(log.trips[0].id)
        #expect(log.trips.map(\.train) == ["ICE 1"])
    }
}
