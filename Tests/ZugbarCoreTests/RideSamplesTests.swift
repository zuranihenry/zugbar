import Foundation
import Testing
@testable import ZugbarCore

struct RideSamplesTests {
    let start = utc("2026-06-12T16:00:00Z")

    /// On board with the next stop `delay` minutes late for `reasons`.
    func status(speed: Int?, delay: Int = 0, reasons: [String] = [], latitude: Double = 50) -> TrainStatus {
        let arrival = start.addingTimeInterval(3600)
        let stops = [
            Stop(id: "a", name: "A", scheduledDeparture: start, passed: true, coordinate: Coordinate(latitude: 50, longitude: 8)),
            Stop(id: "b", name: "B", scheduledArrival: arrival, expectedArrival: arrival.addingTimeInterval(Double(delay) * 60),
                 delayReasons: reasons, coordinate: Coordinate(latitude: 51, longitude: 8)),
        ]
        return TrainStatus(provider: "ICE Portal", trainName: "ICE 1", speed: speed, stops: stops,
                           position: Coordinate(latitude: latitude, longitude: 8))
    }

    @Test func samplesEveryHalfMinute() {
        var sampler = RideSampler()
        // Polled every 5 s: 100 km/h for a minute, then 200 km/h, 3 min late from 1:30 on.
        for second in stride(from: 0, through: 120, by: 5) {
            let speed = second < 60 ? 100 : 200
            sampler.record(status(speed: speed, delay: second < 90 ? 0 : 3), distance: Double(second) / 36, at: Double(second))
        }
        #expect(sampler.samples.map(\.time) == [25, 55, 85, 115])
        #expect(sampler.samples.map(\.speed) == [100, 100, 200, 200])
        #expect(sampler.samples.map(\.delay) == [0, 0, 0, 3])
        #expect(sampler.samples[3].distance == 3.2)
        // The last poll starts the next sample, which the live chart already shows.
        #expect(sampler.all.count == 5)
        #expect(sampler.all.last == RideSample(time: 120, distance: 3.3, speed: 200, delay: 3))
    }

    @Test func averagesTheSpeedAndKeepsTheLastDelay() {
        var sampler = RideSampler()
        sampler.record(status(speed: 90, delay: 2), distance: 0, at: 0)
        sampler.record(status(speed: 110, delay: 4), distance: 0.5, at: 10)
        // A poll without speed or delay, e.g. a portal between two fixes.
        var noData = status(speed: nil)
        noData.stops[1].expectedArrival = nil
        sampler.record(noData, distance: 0.8, at: 20)
        #expect(sampler.all == [RideSample(time: 20, distance: 0.8, speed: 100, delay: 4)])
        sampler.record(status(speed: nil), distance: 0.8, at: 30)
        #expect(sampler.all.last?.speed == nil)
    }

    @Test func marksEachDelayReasonWhereItFirstCameUp() {
        var sampler = RideSampler()
        let reasons: [Int: [String]] = [60: ["Repair"], 90: ["Repair", "Signal fault"], 150: [], 180: ["Repair"]]
        var current: [String] = []
        for second in stride(from: 0, through: 240, by: 10) {
            current = reasons[second] ?? current
            sampler.record(status(speed: 120, delay: current.count, reasons: current), distance: 0, at: Double(second))
        }
        let marked = sampler.all.filter { $0.reasons != nil }
        #expect(marked.map(\.time) == [80, 110])
        #expect(marked.map(\.reasons) == [["Repair"], ["Signal fault"]])
    }

    @Test func staysBoundedOnLongTrips() {
        var sampler = RideSampler(limit: 40)
        // 3 h polled every 10 s; the train stops for 2 minutes every half hour.
        for second in stride(from: 0, through: 3 * 3600, by: 10) {
            let stopped = second % 1800 < 120
            let reasons = second >= 5000 ? ["Repair"] : []
            sampler.record(status(speed: stopped ? 0 : 250, reasons: reasons), distance: Double(second) / 15, at: Double(second))
        }
        #expect(sampler.all.count <= 40)
        #expect(sampler.all.count >= 20)
        #expect(sampler.interval == 30 * 16)
        #expect(sampler.all.last?.time == 3 * 3600)
        #expect(sampler.all.last?.distance == 720)
        #expect(sampler.all.compactMap(\.speed).max() == 250)
        // The reason survives merging, in the sample that now covers when it came up.
        let marked = sampler.all.filter { $0.reasons != nil }
        #expect(marked.map(\.reasons) == [["Repair"]])
        #expect(marked[0].time >= 5000 && marked[0].time < 5000 + 480)
    }

    @Test func breaksLinesAtGapsAndMissingValues() {
        let samples = [
            RideSample(time: 30, distance: 0, speed: 100),
            RideSample(time: 60, distance: 1, speed: 110),
            RideSample(time: 90, distance: 2, speed: 120),
            // The Wi-Fi was gone for 10 min.
            RideSample(time: 690, distance: 30, speed: 80),
            RideSample(time: 720, distance: 31, speed: nil),
            RideSample(time: 750, distance: 32, speed: 90),
            RideSample(time: 780, distance: 33, speed: 95),
        ]
        #expect(samples.runs(of: \.speed).map { $0.map(\.time) } == [[30, 60, 90], [690], [750, 780]])
        #expect(samples.runs(of: \.delay).isEmpty)
        #expect([RideSample]().runs(of: \.speed).isEmpty)
    }

    @Test func tripsKeepTheirSamples() throws {
        var recorder = TripRecorder()
        for minute in stride(from: 0.0, through: 20, by: 0.5) {
            _ = recorder.update(status(speed: 120, delay: minute < 10 ? 0 : 5, latitude: 50 + minute / 30),
                                at: start.addingTimeInterval(minute * 60))
        }
        let live = try #require(recorder.current)
        #expect(live.samples?.count == 41)
        #expect(live.samples?.last?.delay == 5)
        let finished = recorder.finish()
        let trip = try #require(finished)
        #expect(trip.id == live.id)
        #expect(trip.samples == live.samples)
        #expect(abs((trip.samples?.last?.distance ?? 0) - 40) < 0.1)
        #expect(recorder.current == nil)
    }

    @Test func storesSamplesCompactlyAndReadsOlderTrips() throws {
        let sample = RideSample(time: 30, distance: 1.2, speed: 140, delay: 2)
        let json = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
        #expect(json.count < 45)
        #expect(!json.contains("reasons"))
        // Saved before trips had samples.
        let old = """
        {"trips": [{"id": "7D8C2E2A-4F5B-4C1E-9D2A-1B3C4D5E6F70", "train": "ICE 1", "from": "A", "to": "B",
                    "start": 803404800, "end": 803406600, "distance": 55.6, "topSpeed": 250, "arrivalDelay": 3}]}
        """
        let log = try JSONDecoder().decode(TripLog.self, from: Data(old.utf8))
        #expect(log.trips.first?.distance == 55.6)
        #expect(log.trips.first?.samples == nil)
        var trip = try #require(log.trips.first)
        trip.samples = [sample]
        let again = try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip))
        #expect(again == trip)
    }
}
