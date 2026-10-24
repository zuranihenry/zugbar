import Foundation
import Testing
@testable import ZugbarCore

struct GPSMarkerTests {
    let start = utc("2026-06-12T16:00:00Z")
    /// Straight north for about 110 km.
    let route = Route(points: (0...100).map { Coordinate(latitude: 50 + Double($0) * 0.01, longitude: 8) })
    /// Where the last fix of `drive` is.
    let last = 5 * 556.0

    func on(_ meters: Double) -> Coordinate { route.coordinate(at: meters)! }
    func at(_ seconds: Int) -> Date { start.addingTimeInterval(Double(seconds)) }
    func along(_ marker: GPSMarker, at seconds: Int) throws -> Double {
        route.projection(of: try #require(marker.position(at: at(seconds)))).along
    }

    /// Fixes every 10 s, 556 m apart, for a minute: 200 km/h.
    func drive(_ marker: inout GPSMarker, speed: Int = 200, route: Route?, nextStop: Coordinate? = nil) {
        for step in 0...5 {
            marker.update(on(Double(step) * 556), speed: speed, route: route, nextStop: nextStop, at: at(step * 10))
        }
    }

    /// The last fix again every second, as each frame sees it.
    func freeze(_ marker: inout GPSMarker, _ seconds: ClosedRange<Int>, speed: Int, route: Route?, nextStop: Coordinate? = nil) {
        for second in seconds {
            marker.update(on(last), speed: speed, route: route, nextStop: nextStop, at: at(second))
        }
    }

    @Test func goesOnFromEachFixAtTheReportedSpeed() throws {
        var marker = GPSMarker()
        drive(&marker, route: route)
        #expect(try abs(along(marker, at: 50) - last) < 1)
        #expect(try abs(along(marker, at: 55) - (last + 278)) < 1)
    }

    @Test func glidesBetweenFixesWithoutARoute() throws {
        var marker = GPSMarker()
        drive(&marker, route: nil)
        // One fix behind: halfway from the one before to the newest, 5 s after it came.
        #expect(try abs(along(marker, at: 55) - 4.5 * 556) < 1)
        #expect(try abs(along(marker, at: 60) - last) < 1)
    }

    @Test func goesOnAlongTheRouteWhileTheFixIsFrozen() throws {
        var marker = GPSMarker()
        drive(&marker, route: route)
        freeze(&marker, 51...90, speed: 200, route: route)
        // 40 s at 200 km/h.
        #expect(try abs(along(marker, at: 90) - (last + 2_222)) < 2)
        // Slowing down, it goes on more slowly: 30 s at 140 km/h.
        freeze(&marker, 90...120, speed: 140, route: route)
        #expect(try abs(along(marker, at: 120) - (last + 2_222 + 1_167)) < 2)
    }

    @Test func goesOnForTwoMinutesAtMost() throws {
        var marker = GPSMarker()
        drive(&marker, route: route)
        freeze(&marker, 51...300, speed: 200, route: route)
        #expect(try abs(along(marker, at: 300) - (last + 6_667)) < 2)
        #expect(marker.position(at: at(300)) == marker.position(at: at(170)))
    }

    @Test func stopsAtTheNextStop() throws {
        var marker = GPSMarker()
        let stop = on(last + 1_000)
        drive(&marker, route: route, nextStop: stop)
        freeze(&marker, 51...120, speed: 200, route: route, nextStop: stop)
        #expect(try abs(along(marker, at: 120) - (last + 1_000)) < 2)
    }

    @Test func holdsWithoutARouteOrWhenSlow() throws {
        var noRoute = GPSMarker()
        drive(&noRoute, route: nil)
        freeze(&noRoute, 51...120, speed: 200, route: nil)
        #expect(noRoute.position(at: at(120)) == on(last))

        var slow = GPSMarker()
        drive(&slow, speed: 20, route: route)
        freeze(&slow, 51...120, speed: 20, route: route)
        #expect(try abs(along(slow, at: 120) - last) < 1)
    }

    @Test func catchesUpWithAFixAhead() throws {
        var marker = GPSMarker()
        drive(&marker, route: route)
        freeze(&marker, 51...120, speed: 200, route: route)
        let reckoned = try along(marker, at: 120)
        // The next fix is well ahead: no jump, it catches up within 10 s.
        let fresh = last + 6_000
        marker.update(on(fresh), speed: 200, route: route, nextStop: nil, at: at(120))
        #expect(try abs(along(marker, at: 120) - reckoned) < 1)
        #expect(try along(marker, at: 125) > reckoned + 278)
        #expect(try abs(along(marker, at: 130) - (fresh + 556)) < 1)
    }

    @Test func slowsDownForAFixBehind() throws {
        var marker = GPSMarker()
        drive(&marker, route: route)
        freeze(&marker, 51...120, speed: 200, route: route)
        let reckoned = try along(marker, at: 120)
        // A late fix, behind where the marker got to: it goes on at half speed until they meet, never back.
        let late = reckoned - 500
        marker.update(on(late), speed: 200, route: route, nextStop: nil, at: at(120))
        var previous = reckoned
        for second in 121...140 {
            let now = try along(marker, at: second)
            #expect(now > previous)
            previous = now
        }
        #expect(try abs(along(marker, at: 125) - (reckoned + 139)) < 1)
        #expect(try abs(along(marker, at: 140) - (late + 1_111)) < 1)
    }
}
