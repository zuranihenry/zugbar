import Foundation
import Testing
@testable import ZugbarCore

struct HeadingTests {
    let start = utc("2026-06-12T16:00:00Z")

    @Test func bearings() {
        let origin = Coordinate(latitude: 50, longitude: 8)
        #expect(abs(origin.bearing(to: Coordinate(latitude: 51, longitude: 8))) < 0.01)
        #expect(abs(origin.bearing(to: Coordinate(latitude: 50, longitude: 9)) - 89.6) < 0.1)
        #expect(abs(origin.bearing(to: Coordinate(latitude: 49, longitude: 8)) - 180) < 0.01)
        #expect(abs(origin.bearing(to: Coordinate(latitude: 50, longitude: 7)) - 270.4) < 0.1)
    }

    @Test func ignoresJitterAtStandstill() {
        var heading = Heading()
        for second in 0..<30 {
            let wobble = Double(second % 3 - 1) * 0.0001 // about ±10 m
            heading.update(Coordinate(latitude: 50 + wobble, longitude: 8 - wobble), at: start.addingTimeInterval(Double(second)))
        }
        #expect(heading.degrees == nil)
    }

    @Test func turnsGentlyIntoACurve() throws {
        var heading = Heading()
        // North at 50 m/s for 20 s, then east.
        for second in 0...20 {
            heading.update(Coordinate(latitude: 50 + Double(second) * 0.00045, longitude: 8), at: start.addingTimeInterval(Double(second)))
        }
        #expect(try abs(#require(heading.degrees)) < 1)
        let corner = Coordinate(latitude: 50 + 20 * 0.00045, longitude: 8)
        for second in 1...2 {
            heading.update(Coordinate(latitude: corner.latitude, longitude: 8 + Double(second) * 0.0007), at: start.addingTimeInterval(Double(20 + second)))
        }
        let early = try #require(heading.degrees)
        #expect(early > 10 && early < 70)
        for second in 3...20 {
            heading.update(Coordinate(latitude: corner.latitude, longitude: 8 + Double(second) * 0.0007), at: start.addingTimeInterval(Double(20 + second)))
        }
        #expect(try abs(#require(heading.degrees) - 90) < 2)
    }

    @Test func turnsTheShortWayAcrossNorth() throws {
        var heading = Heading()
        // Heading 350°, then 10°: should pass through north, not swing round via south.
        var position = Coordinate(latitude: 50, longitude: 8)
        for second in 0...10 {
            position = Coordinate(latitude: position.latitude + 0.00044, longitude: position.longitude - 0.00012)
            heading.update(position, at: start.addingTimeInterval(Double(second)))
        }
        for second in 11...13 {
            position = Coordinate(latitude: position.latitude + 0.00044, longitude: position.longitude + 0.00012)
            heading.update(position, at: start.addingTimeInterval(Double(second)))
            let degrees = try #require(heading.degrees)
            #expect(degrees > 340 || degrees < 20)
        }
    }
}
