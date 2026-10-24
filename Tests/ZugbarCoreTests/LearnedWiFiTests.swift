import Foundation
import Testing
@testable import ZugbarCore

struct LearnedWiFiTests {
    /// A made-up straight line, 50 km due north.
    let route = Route(points: (0...50).map { Coordinate(latitude: 50 + Double($0) * 0.009, longitude: 9.3) })
    let now = Date(timeIntervalSince1970: 1_000_000)

    /// One ride's verdicts every 100 m between two points on the route, in km.
    func learn(_ quality: Internet.Quality, from start: Double, to end: Double, into learned: inout LearnedWiFi) {
        for meters in stride(from: start * 1000, through: end * 1000, by: 100) {
            learned.record(quality, at: route.coordinate(at: meters)!)
        }
    }

    func status(at km: Double?, speed: Int? = 180, quality: Internet.Quality = .good, train: String = "ICE 1") -> TrainStatus {
        TrainStatus(provider: "Deutsche Bahn", trainName: train, speed: speed, internet: Internet(current: quality),
                    position: km.flatMap { route.coordinate(at: $0 * 1000) }, route: route)
    }

    // MARK: - Cells

    @Test func cellsGoWithMostRidesErringOnTheBadSide() {
        var learned = LearnedWiFi()
        let here = route.coordinate(at: 5000)!
        #expect(learned.quality(at: here) == nil)
        learned.record(.good, at: here)
        #expect(learned.quality(at: here) == .good)
        learned.record(.weak, at: here)
        #expect(learned.quality(at: here) == .weak)
        learned.record(.none, at: here)
        learned.record(.none, at: here)
        #expect(learned.quality(at: here) == Internet.Quality.none)
        #expect(learned.cellCount == 1)
    }

    @Test func emptyCellsAskTheirNeighbors() {
        var learned = LearnedWiFi()
        learned.record(.weak, at: Coordinate(latitude: 50.1001, longitude: 9.3001))
        // The next cell east, as where a route's line runs a little beside the GPS fixes.
        #expect(learned.quality(at: Coordinate(latitude: 50.1001, longitude: 9.3041)) == .weak)
        #expect(learned.quality(at: Coordinate(latitude: 50.1001, longitude: 9.3121)) == nil)
    }

    @Test func newerRidesWinWithinAFewTrips() {
        var learned = LearnedWiFi()
        let here = route.coordinate(at: 5000)!
        for _ in 0..<30 { learned.record(.good, at: here) }
        for _ in 0..<5 { learned.record(.none, at: here) }
        #expect(learned.quality(at: here) == .good)
        learned.record(.none, at: here)
        #expect(learned.quality(at: here) == Internet.Quality.none)
    }

    @Test func roundTripsThroughJSON() throws {
        var learned = LearnedWiFi()
        learn(.weak, from: 1, to: 2, into: &learned)
        let decoded = try JSONDecoder().decode(LearnedWiFi.self, from: JSONEncoder().encode(learned))
        #expect(decoded == learned)
    }

    // MARK: - Stretches

    @Test func smoothsSamplesIntoStretches() {
        func run(_ quality: Internet.Quality?, _ count: Int) -> [Internet.Quality?] { Array(repeating: quality, count: count) }
        let samples = run(.good, 20) + run(nil, 3) + run(.good, 10) // a cell crossed between polls
            + run(.weak, 2) + run(.good, 20) // a dip too short to matter
            + run(.weak, 10) + run(nil, 30) + run(Internet.Quality.none, 10) // into a tunnel, no GPS inside
            + run(.good, 10) + run(nil, 20) + run(Internet.Quality.none, 10) // nothing known between good and offline
        let stretches = LearnedWiFi.stretches(from: samples).map { [$0.start, $0.end] }
        #expect(stretches == [[0, 5500], [5500, 6500], [6500, 10_500], [10_500, 11_500], [13_500, 14_500]])
        #expect(LearnedWiFi.stretches(from: samples).map(\.quality) == [.good, .weak, .none, .good, .none])
    }

    // MARK: - Forecast

    @Test func findsTheWeakStretchAhead() throws {
        var learned = LearnedWiFi()
        learn(.good, from: 0, to: 10, into: &learned)
        learn(.weak, from: 10, to: 12, into: &learned)
        learn(.good, from: 12, to: 50, into: &learned)

        // At km 2, at 180 km/h (50 m/s): about 8 km and 160 s to the weak stretch.
        let forecast = try #require(learned.forecast(along: route, from: 2000, to: 40_000, speed: 180, at: now))
        let next = try #require(forecast.next(after: .good))
        #expect(next.quality == .weak)
        #expect((7_600...8_300).contains(next.start))
        #expect((9_600...10_300).contains(next.end))

        let internet = forecast.filling(Internet(current: .good))
        #expect(internet.next == .weak)
        #expect(internet.learned)
        let seconds = try #require(internet.nextChange).timeIntervalSince(now)
        #expect((150...170).contains(seconds))

        // In the weak stretch, the next change is back to good.
        let inside = try #require(learned.forecast(along: route, from: 10_800, to: 40_000, speed: 180, at: now))
        #expect(inside.filling(Internet(current: .weak)).next == .good)
    }

    @Test func thePortalsOwnForecastWins() throws {
        var learned = LearnedWiFi()
        learn(.good, from: 0, to: 5, into: &learned)
        learn(.none, from: 5, to: 8, into: &learned)
        let forecast = try #require(learned.forecast(along: route, from: 0, to: 20_000, speed: 200, at: now))
        let portal = Internet(current: .good, next: .weak, nextChange: now.addingTimeInterval(30))
        #expect(forecast.filling(portal) == portal)
    }

    @Test func nothingWhenSlowOrUnknown() {
        var learned = LearnedWiFi()
        #expect(learned.forecast(along: route, from: 0, to: 20_000, speed: 200, at: now) == nil)
        learn(.good, from: 0, to: 5, into: &learned)
        learn(.none, from: 5, to: 8, into: &learned)
        #expect(learned.forecast(along: route, from: 0, to: 20_000, speed: 20, at: now) == nil)
        #expect(learned.forecast(along: route, from: 0, to: 20_000, speed: 200, at: now) != nil)
    }

    @Test func looksNoFurtherThanTheNextStop() throws {
        var learned = LearnedWiFi()
        learn(.good, from: 0, to: 10, into: &learned)
        learn(.none, from: 10, to: 15, into: &learned)
        learn(.good, from: 15, to: 50, into: &learned)
        var train = status(at: 2)
        train.stops = [Stop(id: "a", name: "A", passed: true, coordinate: route.coordinate(at: 0)),
                       Stop(id: "b", name: "B", coordinate: route.coordinate(at: 6000)),
                       Stop(id: "c", name: "C", coordinate: route.coordinate(at: 30_000))]
        let short = try #require(learned.forecast(for: train, along: 2000, at: now))
        #expect(short.next(after: .good) == nil)

        train.stops[1].passed = true
        let long = try #require(learned.forecast(for: train, along: 7000, at: now))
        #expect(long.next(after: .good)?.quality == Internet.Quality.none)
    }

    // MARK: - Tracker

    @Test func oneVerdictPerCellAndRide() {
        var tracker = WiFiTracker()
        var verdicts: [WiFiTracker.Verdict] = []
        var date = now
        // 0 to 5 km at 180 km/h, polled every 3 s: good for the first half, then offline.
        for meters in stride(from: 0.0, through: 5000, by: 150) {
            verdicts += tracker.update(status(at: meters / 1000, quality: meters < 2500 ? .good : .none), at: date)
            date += 3
        }
        let cells = verdicts.map { LearnedSpeeds.index($0.coordinate) }
        #expect(Set(cells.map { "\($0.0)|\($0.1)" }).count == cells.count)
        #expect(cells.count >= 16)
        for verdict in verdicts {
            let km = route.projection(of: verdict.coordinate).along / 1000
            if km < 2.2 { #expect(verdict.quality == .good) }
            if km > 2.6 { #expect(verdict.quality == Internet.Quality.none) }
        }

        // Standing adds nothing until the train leaves the cell; jittering back and forth after that adds nothing.
        for _ in 0..<20 {
            #expect(tracker.update(status(at: 5, speed: 0), at: date).isEmpty)
            date += 3
        }
        #expect(tracker.update(status(at: 4.7, speed: 0), at: date).count == 1)
        #expect(tracker.update(status(at: 5, speed: 0), at: date + 3).isEmpty)
        #expect(tracker.update(status(at: 4.7, speed: 0), at: date + 6).isEmpty)

        // Another train is another ride.
        #expect(tracker.update(status(at: 5, train: "ICE 2"), at: date + 9).isEmpty)
        #expect(tracker.update(status(at: 4.7, train: "ICE 2"), at: date + 12).count == 1)
    }

    @Test func carriesTheTrainOnThroughATunnel() throws {
        var tracker = WiFiTracker()
        var verdicts = tracker.update(status(at: 1), at: now)
        // 20 polls without GPS at 180 km/h: 3 km on along the line.
        for index in 1...20 {
            verdicts += tracker.update(status(at: nil, quality: .none), at: now + Double(index) * 3)
        }
        #expect(abs(try #require(tracker.along) - 4000) < 1)
        let inside = verdicts.filter { route.projection(of: $0.coordinate).along > 1400 }
        #expect(inside.count >= 8)
        #expect(inside.allSatisfy { $0.quality == Internet.Quality.none })
    }

    @Test func carriesOnBetweenStaleFixesButNotTooFar() throws {
        var tracker = WiFiTracker()
        _ = tracker.update(status(at: 1), at: now)
        _ = tracker.update(status(at: 1), at: now + 3)
        _ = tracker.update(status(at: 1), at: now + 6)
        #expect(abs(try #require(tracker.along) - 1300) < 1)
        // A new fix puts it back where the GPS says.
        _ = tracker.update(status(at: 1.2), at: now + 9)
        #expect(abs(try #require(tracker.along) - 1200) < 5)

        // 300 km/h without a fix for five minutes is too far to guess.
        for index in 1...5 { _ = tracker.update(status(at: nil, speed: 300), at: now + 9 + Double(index) * 60) }
        #expect(tracker.along == nil)
    }

    // MARK: - Dead zone alert

    @Test func warnsOnceShortlyBeforeALongDeadZone() {
        // 50 m/s: offline from 120 s to 400 s ahead.
        let forecast = WiFiForecast(
            stretches: [.init(quality: .good, start: 0, end: 6000), .init(quality: .none, start: 6000, end: 20_000)],
            speed: 50, date: now
        )
        var alert = DeadZoneAlert()
        #expect(alert.check(forecast, current: .good, at: now - 30) == nil)
        let warning = alert.check(forecast, current: .good, at: now)
        #expect(warning?.start == now + 120)
        #expect(warning?.end == now + 400)
        #expect(alert.check(forecast, current: .good, at: now + 10) == nil)

        var offline = DeadZoneAlert()
        #expect(offline.check(forecast, current: .none, at: now) == nil)

        let short = WiFiForecast(stretches: [.init(quality: .none, start: 6000, end: 12_000)], speed: 50, date: now)
        var brief = DeadZoneAlert()
        #expect(brief.check(short, current: .good, at: now) == nil)
    }
}
