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
        // 1/60° of latitude a minute is 111 km/h.
        for minute in stride(from: 0.0, through: 30, by: 1) {
            let finished = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: minute == 15 ? 115 : 111),
                                           at: start.addingTimeInterval(minute * 60))
            #expect(finished == nil)
        }
        let finished = recorder.finish()
        let trip = try #require(finished)
        #expect(trip.train == "ICE 1")
        #expect(trip.from == "A")
        #expect(trip.to == "B")
        #expect(abs(trip.distance - 55.6) < 0.5)
        #expect(trip.topSpeed == 115)
        #expect(trip.arrivalDelay == 3)
        #expect(trip.duration == 30 * 60)
        let again = recorder.finish()
        #expect(again == nil)
    }

    @Test func countsFastTrainsPolledOftenWithLaggingFixes() throws {
        var recorder = TripRecorder()
        // Polled every 3 s at 250 km/h, but the fix moves only every 9 s: once back to an older fix, once 10 km off.
        let fixStep = 250.0 * 9 / 3600 / 111.195
        for poll in 0...200 {
            var latitude = 50 + Double(poll / 3) * fixStep
            if poll == 100 { latitude -= 3 * fixStep }
            if poll == 150 { latitude += 0.09 }
            _ = recorder.update(onBoard(Double(poll) / 20, latitude: latitude, speed: 250), at: start.addingTimeInterval(Double(poll) * 3))
        }
        let finished = recorder.finish()
        let trip = try #require(finished)
        #expect(abs(trip.distance - 41.7) < 1)
        #expect(trip.topSpeed == 250)
    }

    @Test func fallsBackToGPSAfterAGap() throws {
        var recorder = TripRecorder()
        let km = 1 / 111.195
        for minute in stride(from: 0.0, through: 5, by: 1) {
            _ = recorder.update(onBoard(minute, latitude: 50 + 2 * minute * km, speed: 120), at: start.addingTimeInterval(minute * 60))
        }
        // No Wi-Fi for 10 min, in which the train went 20 km and stopped: the speeds either side can't tell.
        _ = recorder.update(onBoard(15, latitude: 50 + 30 * km, speed: 0), at: start.addingTimeInterval(15 * 60))
        // A bad fix after another gap is still no 3000 km/h.
        _ = recorder.update(onBoard(17, latitude: 50 + 130 * km, speed: 0), at: start.addingTimeInterval(17 * 60))
        _ = recorder.update(onBoard(18, latitude: 50 + 30 * km, speed: 0), at: start.addingTimeInterval(18 * 60))
        let finished = recorder.finish()
        let trip = try #require(finished)
        #expect(abs(trip.distance - 30) < 0.5)
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

    @Test func lidClosedHalfwayIsOneTrip() throws {
        var recorder = TripRecorder()
        var log = TripLog()
        for minute in stride(from: 0.0, through: 15, by: 1) {
            _ = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: 111), at: start.addingTimeInterval(minute * 60))
        }
        // The lid closed for 40 min: the first part is logged meanwhile.
        let idle = recorder.finishIfIdle(at: start.addingTimeInterval(36 * 60))
        let firstPart = try #require(idle)
        log.add(firstPart)
        // Awake again, further on along the same ride.
        for minute in stride(from: 55.0, through: 60, by: 1) {
            let finished = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: 111), at: start.addingTimeInterval(minute * 60))
            #expect(finished == nil)
        }
        let finished = recorder.finish()
        let trip = try #require(finished)
        log.add(trip)
        #expect(trip.id == firstPart.id)
        #expect(trip.from == "A")
        #expect(abs(trip.distance - 111.2) < 1)
        #expect(log.trips.count == 1)
        #expect(log.trips.first?.distance == trip.distance)
    }

    @Test func goesOnFromTheFirstPollAfterSleep() throws {
        var recorder = TripRecorder()
        for minute in stride(from: 0.0, through: 15, by: 1) {
            _ = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: 111), at: start.addingTimeInterval(minute * 60))
        }
        // No tick ran while asleep; the first poll finds the ride idle and goes straight on with it.
        let finished = recorder.update(onBoard(50, latitude: 50 + 50.0 / 60, speed: 111), at: start.addingTimeInterval(50 * 60))
        #expect(finished == nil)
        #expect(recorder.current.map { abs($0.distance - 92.7) < 1 } == true)
    }

    @Test func portalDownWhileFollowedOnlineIsOneTrip() throws {
        var recorder = TripRecorder()
        for minute in stride(from: 0.0, through: 10, by: 1) {
            _ = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: 111), at: start.addingTimeInterval(minute * 60))
        }
        let online = TrainStatus(provider: "Transitous", trainName: "ICE 1", stops: stops)
        for minute in stride(from: 11.0, through: 40, by: 1) {
            _ = recorder.update(online, at: start.addingTimeInterval(minute * 60))
            _ = recorder.finishIfIdle(at: start.addingTimeInterval(minute * 60 + 30))
        }
        _ = recorder.update(onBoard(41, latitude: 50 + 41.0 / 60, speed: 111), at: start.addingTimeInterval(41 * 60))
        let finished = recorder.finish()
        let trip = try #require(finished)
        #expect(trip.from == "A")
        #expect(trip.duration == 41 * 60)
    }

    @Test func theNextRunIsANewTrip() throws {
        var recorder = TripRecorder()
        for minute in stride(from: 0.0, through: 15, by: 1) {
            _ = recorder.update(onBoard(minute, latitude: 50 + minute / 60, speed: 111), at: start.addingTimeInterval(minute * 60))
        }
        let idle = recorder.finishIfIdle(at: start.addingTimeInterval(36 * 60))
        let firstPart = try #require(idle)
        // An hour later, a train of the same name to the same end, but leaving A an hour later.
        var next = onBoard(75, latitude: 50.1, speed: 111)
        next.stops[0].scheduledDeparture = stops[0].scheduledDeparture?.addingTimeInterval(3600)
        _ = recorder.update(next, at: start.addingTimeInterval(75 * 60))
        #expect(recorder.current?.id != firstPart.id)
        #expect(recorder.current?.distance == 0)
        // Long after, even the same run is a new trip.
        var later = TripRecorder()
        _ = later.update(onBoard(0, latitude: 50, speed: 111), at: start)
        _ = later.update(onBoard(10, latitude: 50 + 10.0 / 60, speed: 111), at: start.addingTimeInterval(600))
        let idleLater = later.finishIfIdle(at: start.addingTimeInterval(31 * 60))
        let ended = try #require(idleLater)
        _ = later.update(onBoard(0, latitude: 50.2, speed: 111), at: start.addingTimeInterval(4 * 3600))
        #expect(later.current?.id != ended.id)
    }

    @Test func withoutTimesWhereItBeganANewTrip() throws {
        var recorder = TripRecorder()
        func untimed(_ minute: Double) -> TrainStatus {
            var status = onBoard(minute, latitude: 50 + minute / 60, speed: 111)
            status.stops[0].scheduledDeparture = nil
            return status
        }
        for minute in stride(from: 0.0, through: 15, by: 1) {
            _ = recorder.update(untimed(minute), at: start.addingTimeInterval(minute * 60))
        }
        let idle = recorder.finishIfIdle(at: start.addingTimeInterval(36 * 60))
        let firstPart = try #require(idle)
        // Nothing tells this run from the next one of the same name.
        _ = recorder.update(untimed(55), at: start.addingTimeInterval(55 * 60))
        #expect(recorder.current?.id != firstPart.id)
        #expect(recorder.current?.distance == 0)
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
