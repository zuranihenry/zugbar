import Foundation
import Testing
@testable import ZugbarCore

struct GPSFilterTests {
    let start = utc("2026-06-12T16:00:00Z")

    /// Northbound at about 240 km/h, with a new fix every 10 s (about 670 m apart).
    func north(_ step: Int) -> Coordinate {
        Coordinate(latitude: 50 + Double(step) * 0.006, longitude: 8)
    }

    func at(_ seconds: Int) -> Date { start.addingTimeInterval(Double(seconds)) }

    @Test func holdsARepeatedOldFix() {
        var filter = GPSFilter()
        for step in 0...12 {
            #expect(filter.filter(north(step), speed: 240, at: at(step * 10)) == north(step))
        }
        // The fix from a minute ago again, about 4 km back, for two polls: the train stays where it was.
        #expect(filter.filter(north(6), speed: 240, at: at(123)) == north(12))
        #expect(filter.filter(north(6), speed: 240, at: at(126)) == north(12))
        // Then a current fix again, ahead.
        #expect(filter.filter(north(13), speed: 240, at: at(130)) == north(13))
        #expect(filter.filter(north(14), speed: 240, at: at(140)) == north(14))
    }

    @Test func aLateFixDoesNotTurnTheTrainRound() {
        var filter = GPSFilter()
        for step in 0...6 {
            _ = filter.filter(north(step), speed: 240, at: at(step * 10))
        }
        // 60 m behind: GPS jitter, let through, but the train still goes north.
        let late = Coordinate(latitude: north(6).latitude - 0.00055, longitude: 8)
        #expect(filter.filter(late, speed: 240, at: at(65)) == late)
        #expect(filter.filter(north(7), speed: 240, at: at(70)) == north(7))
        #expect(filter.filter(north(4), speed: 240, at: at(75)) == north(7))
    }

    @Test func takesAReversalAfterStanding() {
        var filter = GPSFilter()
        for step in 0...6 {
            _ = filter.filter(north(step), speed: 240, at: at(step * 10))
        }
        // Stands at a terminus for two minutes, then leaves southbound; its first new fix is already 200 m back.
        for second in stride(from: 70, through: 190, by: 10) {
            #expect(filter.filter(north(6), speed: 0, at: at(second)) == north(6))
        }
        for step in 1...6 {
            let back = Coordinate(latitude: north(6).latitude - Double(step) * 0.0018, longitude: 8)
            #expect(filter.filter(back, speed: 20 * step, at: at(190 + step * 20)) == back)
        }
    }

    @Test func passesForwardMotion() {
        var filter = GPSFilter()
        // North, then through a curve to the east, with about 30 m of sideways jitter.
        var position = Coordinate(latitude: 50, longitude: 8)
        for step in 0..<40 {
            let bearing = min(Double(max(step - 10, 0)) * 6, 90) * .pi / 180
            let jitter = Double(step % 3 - 1) * 0.0003
            position = Coordinate(latitude: position.latitude + cos(bearing) * 0.003,
                                  longitude: position.longitude + sin(bearing) * 0.0045)
            let fix = Coordinate(latitude: position.latitude - sin(bearing) * jitter, longitude: position.longitude + cos(bearing) * jitter)
            #expect(filter.filter(fix, speed: 120, at: at(step * 10)) == fix)
        }
        // Jitter of less than 100 m backwards passes too.
        let jitter = Coordinate(latitude: position.latitude, longitude: position.longitude - 0.001)
        #expect(filter.filter(jitter, speed: 120, at: at(400)) == jitter)
    }

    @Test func givesUpAfterAMinute() {
        var filter = GPSFilter()
        for step in 0...6 {
            _ = filter.filter(north(step), speed: 240, at: at(step * 10))
        }
        // Fixes keep coming from behind with the speed still up: after a minute they count.
        let behind = north(3)
        for second in stride(from: 70, to: 120, by: 10) {
            #expect(filter.filter(behind, speed: 240, at: at(second)) == north(6))
        }
        #expect(filter.filter(behind, speed: 240, at: at(120)) == behind)
        // And the train goes on from there.
        #expect(filter.filter(north(4), speed: 240, at: at(130)) == north(4))
    }
}
