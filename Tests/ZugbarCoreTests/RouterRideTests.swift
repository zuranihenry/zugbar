import Foundation
import Testing
@testable import ZugbarCore

/// Made-up places on an invented line running north.
private func point(_ km: Double, east: Double = 0) -> Coordinate {
    Coordinate(latitude: 45 + km / 111.2, longitude: 7 + east / (111.32 * cos(45 * .pi / 180)))
}

/// Google polyline encoding, to build made-up segment shapes.
private func encode(_ points: [Coordinate], precision: Double = 1e5) -> String {
    var result = ""
    var last = (0, 0)
    func add(_ value: Int) {
        var v = value < 0 ? ~(value << 1) : value << 1
        while v >= 0x20 {
            result.append(Character(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63))))
            v >>= 5
        }
        result.append(Character(UnicodeScalar(UInt8(v + 63))))
    }
    for point in points {
        let (lat, lon) = (Int((point.latitude * precision).rounded()), Int((point.longitude * precision).rounded()))
        add(lat - last.0)
        add(lon - last.1)
        last = (lat, lon)
    }
    return result
}

struct RouteProjectionTests {
    @Test func middleOfALongPiece() {
        let route = Route(points: [point(0), point(3)])
        let position = route.projection(of: point(1.5, east: 0.05))
        #expect(abs(position.along - 1500) < 20)
        #expect(abs(position.offset - 0.05) < 0.005)
        #expect(abs(position.pieceLength - 3000) < 20)
    }

    @Test func pastTheEnd() {
        let route = Route(points: [point(0), point(3)])
        let position = route.projection(of: point(5))
        #expect(abs(position.along - route.length) < 1)
        #expect(abs(position.offset - 2) < 0.02)
    }

    @Test func reversingTrain() {
        // Out and back on the same track: with the direction, the fix lands on the leg going that way.
        let route = Route(points: [point(0), point(5), point(0.001)])
        let back = route.projection(of: point(2), heading: 180)
        #expect(back.along > 5000)
        let out = route.projection(of: point(2), heading: 0)
        #expect(out.along < 5000)
    }

    @Test func bearing() throws {
        let route = Route(points: [point(0), point(3), point(3, east: 3)])
        #expect(try abs(#require(route.bearing(at: 1000))) < 1)
        #expect(try abs(#require(route.bearing(at: 4500)) - 90) < 1)
    }
}

struct MatcherTests {
    let now = utc("2026-03-02T12:00:00Z")

    func segment(_ name: String, mode: String = "REGIONAL_RAIL", from: Coordinate, to: Coordinate,
                 departedMinutesAgo: Double, minutes: Double = 10, shape: [Coordinate]? = nil) -> String {
        let departure = now.addingTimeInterval(-departedMinutesAgo * 60)
        let arrival = departure.addingTimeInterval(minutes * 60)
        let polyline = shape.map { #","polyline":"\#(encode($0).replacingOccurrences(of: "\\", with: "\\\\"))""# } ?? ""
        return """
        {"mode":"\(mode)","trips":[{"tripId":"\(name)","displayName":"\(name)"}],
         "from":{"name":"A","lat":\(from.latitude),"lon":\(from.longitude)},
         "to":{"name":"B","lat":\(to.latitude),"lon":\(to.longitude)},
         "departure":"\(departure.formatted(.iso8601))","arrival":"\(arrival.formatted(.iso8601))"\(polyline)}
        """
    }

    func match(_ segments: [String], at coordinate: Coordinate, heading: Double) throws -> String? {
        let data = Data("[\(segments.joined(separator: ","))]".utf8)
        let decoded = try JSONDecoder.portal.decode([TransitousClient.Segment].self, from: data)
        return TransitousClient.train(at: coordinate, heading: heading, in: decoded, now: now)?.name
    }

    @Test func direction() throws {
        let north = segment("RB 1", from: point(0), to: point(10), departedMinutesAgo: 5)
        let south = segment("RB 2", from: point(10), to: point(0), departedMinutesAgo: 5)
        #expect(try match([north, south], at: point(5), heading: 2) == "RB 1")
        #expect(try match([north, south], at: point(5), heading: 182) == "RB 2")
        #expect(try match([north], at: point(5), heading: 355) == "RB 1")
        #expect(try match([north], at: point(5), heading: 90) == nil)
    }

    @Test func regionalFirst() throws {
        let fast = segment("ICE 1", mode: "HIGHSPEED_RAIL", from: point(0), to: point(10), departedMinutesAgo: 5)
        let slow = segment("RE 1", from: point(0), to: point(10), departedMinutesAgo: 11, minutes: 12)
        #expect(try match([fast, slow], at: point(5), heading: 0) == "RE 1")
        #expect(try match([fast], at: point(5), heading: 0) == "ICE 1")
    }

    @Test func lag() throws {
        // Halfway along at 12:00 means 5 min after departure; 19 min late still counts, 21 doesn't.
        #expect(try match([segment("RB 1", from: point(0), to: point(10), departedMinutesAgo: 24)], at: point(5), heading: 0) == "RB 1")
        #expect(try match([segment("RB 1", from: point(0), to: point(10), departedMinutesAgo: 26)], at: point(5), heading: 0) == nil)
        // Of two trains on the line, the one closer in time.
        let early = segment("RB 1", from: point(0), to: point(10), departedMinutesAgo: 12)
        let onTime = segment("RB 3", from: point(0), to: point(10), departedMinutesAgo: 6)
        #expect(try match([early, onTime], at: point(5), heading: 0) == "RB 3")
    }

    @Test func offTheLine() throws {
        let line = segment("RB 1", from: point(0), to: point(10), departedMinutesAgo: 5)
        #expect(try match([line], at: point(5, east: 2), heading: 0) == nil)
        // Past the last stop, on a branch.
        #expect(try match([line], at: point(12, east: 0.8), heading: 20) == nil)
        #expect(try match([segment("RB 1", from: point(0), to: point(0), departedMinutesAgo: 5)], at: point(0), heading: 0) == nil)
    }

    @Test func followsTheShape() throws {
        // A curve 1.2 km off the straight line between the stops: on the track counts, off it doesn't.
        let shape = [point(0), point(3, east: 1.2), point(7, east: 1.2), point(10)]
        let curved = segment("RB 1", from: point(0), to: point(10), departedMinutesAgo: 5, shape: shape)
        #expect(try match([curved], at: point(5, east: 1.2), heading: 0) == "RB 1")
        #expect(try match([curved], at: point(5), heading: 0) == nil)
    }
}

struct RouterRideTests {
    let start = utc("2026-03-02T12:00:00Z")

    func fix(_ km: Double, speed: Int = 100, age: TimeInterval = 0) -> Icomera.Fix {
        Icomera.Fix(coordinate: point(km), speed: speed, heading: 180, age: age)
    }

    @Test func headingFromTheFixes() {
        var ride = RouterRide()
        ride.received(fix(0), at: start)
        #expect(ride.heading == nil)
        // Jitter while standing doesn't count.
        ride.received(fix(0.02, speed: 0), at: start.addingTimeInterval(3))
        #expect(ride.heading == nil)
        ride.received(fix(0.1), at: start.addingTimeInterval(6))
        // North, whatever the router's own course says.
        #expect(abs(ride.heading ?? 999) < 1)
    }

    @Test func freshness() {
        var ride = RouterRide()
        ride.received(fix(0, age: 10), at: start)
        #expect(ride.freshFix(at: start.addingTimeInterval(15)) != nil)
        #expect(ride.freshFix(at: start.addingTimeInterval(21)) == nil)
    }

    @Test func searching() {
        var ride = RouterRide()
        ride.received(fix(0), at: start)
        #expect(!ride.shouldSearch(at: start))
        ride.received(fix(0.2), at: start.addingTimeInterval(3))
        var now = start.addingTimeInterval(3)
        #expect(ride.shouldSearch(at: now))
        ride.searched(found: false, at: now)
        #expect(!ride.shouldSearch(at: now.addingTimeInterval(10)))
        now = now.addingTimeInterval(15)
        ride.received(fix(0.6), at: now)
        #expect(ride.shouldSearch(at: now))
        // Standing still: the trains at a station can't be told apart.
        ride.received(fix(0.6, speed: 0), at: now.addingTimeInterval(3))
        #expect(!ride.shouldSearch(at: now.addingTimeInterval(3)))
    }

    @Test func pickSurvivesANewNetwork() {
        var ride = RouterRide()
        ride.received(fix(0), at: start)
        ride.picked(.init(tripID: "t1", label: "RB 1"))
        ride.joinedNetwork()
        let pick = ride.pickToFollow(at: start)
        #expect(pick?.tripID == "t1")
        #expect(ride.fix == nil)
    }

    @Test func routerGoneKeepsFollowingUntilTheDeadline() {
        var ride = RouterRide()
        ride.received(fix(0), at: start)
        ride.picked(.init(tripID: "t1", label: "RB 1"))
        let deadline = start.addingTimeInterval(3600)
        ride.followed(until: deadline)
        for _ in 0..<4 { ride.unreachable() }
        #expect(ride.isGone)
        let before = ride.pickToFollow(at: start.addingTimeInterval(60))
        #expect(before?.tripID == "t1")
        let after = ride.pickToFollow(at: deadline)
        #expect(after == nil)

        var notFollowed = RouterRide()
        notFollowed.picked(.init(tripID: "t1", label: "RB 1"))
        for _ in 0..<4 { notFollowed.unreachable() }
        #expect(notFollowed.pick == nil)
    }

    @Test func stoppedSticksUntilTheRideEnds() {
        var ride = RouterRide()
        ride.received(fix(0), at: start)
        ride.received(fix(0.2), at: start.addingTimeInterval(3))
        ride.picked(.init(tripID: "t1", label: "RB 1"))
        ride.stopped()
        #expect(!ride.shouldSearch(at: start.addingTimeInterval(3)))
        for _ in 0..<4 { ride.unreachable() }
        #expect(!ride.dismissed)
    }

    @Test func wrongTrain() {
        var ride = RouterRide()
        var now = start
        ride.received(fix(0), at: now)
        ride.picked(.init(tripID: "t1", label: "RB 1"))
        for index in 0..<19 {
            now = start.addingTimeInterval(Double(index) * 3)
            ride.received(fix(Double(index) * 0.1), at: now)
            let wrong = ride.isWrongTrain(gpsOnLine: false, at: now)
            #expect(!wrong)
        }
        // One fix on the line starts the count over.
        let onLine = ride.isWrongTrain(gpsOnLine: true, at: now)
        #expect(!onLine)
        for _ in 0..<19 {
            let wrong = ride.isWrongTrain(gpsOnLine: false, at: now)
            #expect(!wrong)
        }
        let wrong = ride.isWrongTrain(gpsOnLine: false, at: now)
        #expect(wrong)
        ride.reject()
        #expect(ride.pick == nil)
        #expect(ride.rejected == ["t1"])
    }

    @Test func lookupFailures() {
        var ride = RouterRide()
        ride.picked(.init(tripID: "t1", label: "RB 1"))
        ride.lookupFailed()
        ride.lookupFailed()
        ride.lookupSucceeded()
        ride.lookupFailed()
        #expect(ride.pick != nil)
        ride.lookupFailed()
        ride.lookupFailed()
        #expect(ride.pick == nil)
        #expect(ride.rejected == ["t1"])
    }

    @Test func answerWithoutFixIsStillOnBoard() {
        var ride = RouterRide()
        ride.picked(.init(tripID: "t1", label: "RB 1"))
        for _ in 0..<3 { ride.unreachable() }
        ride.answeredWithoutFix()
        ride.unreachable()
        #expect(!ride.isGone)
        #expect(ride.pollDelay == 3)
        #expect(ride.pick != nil)
    }

    @Test func requestStopsDontRejectAStoppingTrain() {
        var ride = RouterRide()
        let stops = [2000.0, 6000, 10000, 14000, 18000, 22000]
        var now = start
        var along = 0.0
        var wrong = false
        // Every 3 s; stops at all but two request stops, which it runs through.
        while along < 23000 {
            let near = stops.min { abs($0 - along) < abs($1 - along) }!
            let skipping = near == 10000 || near == 18000
            let speed = abs(near - along) < 150 && !skipping ? 0 : 80
            ride.received(Icomera.Fix(coordinate: point(along / 1000), speed: speed, heading: 0, age: 0), at: now)
            wrong = wrong || ride.skipsStops(along: along, stops: stops, at: now)
            along += speed == 0 ? 60 : 66
            now = now.addingTimeInterval(3)
        }
        #expect(!wrong)
    }
}

struct PlanTests {
    @Test func recent() {
        let now = utc("2026-03-02T12:00:00Z")
        var plan = JourneyPlan(trainName: "RB 1")
        #expect(!plan.isRecent(at: now))
        plan.updated = now.addingTimeInterval(-5 * 3600)
        #expect(plan.isRecent(at: now))
        plan.updated = now.addingTimeInterval(-7 * 3600)
        #expect(!plan.isRecent(at: now))
    }
}

struct StopCheckTests {
    let start = utc("2026-03-02T12:00:00Z")

    /// Fixes every `step` seconds from `from` to `to` meters at a speed given per position.
    func run(_ check: inout StopCheck, from: Double, to: Double, step: TimeInterval = 3, startingAt time: Date,
             stops: [Double], speed: (Double) -> Int) -> (skipped: Int, stopped: Int) {
        var result = (skipped: 0, stopped: 0)
        var (along, now) = (from, time)
        while along <= to {
            let kmh = speed(along)
            result = check.record(along: along, speed: kmh, stops: stops, at: now)
            along += max(Double(kmh) / 3.6 * step, 20)
            now = now.addingTimeInterval(step)
        }
        return result
    }

    @Test func stopsAndSkips() {
        var check = StopCheck()
        let stops = [1000.0, 5000, 9000]
        let result = run(&check, from: 0, to: 6000, startingAt: start, stops: stops) { along in
            abs(along - 1000) < 200 ? 0 : 100
        }
        #expect(result.stopped == 1)
        #expect(result.skipped == 1)
    }

    @Test func firstFixPastAStop() {
        // Picked just after leaving a stop: it never saw the train there.
        var check = StopCheck()
        let result = run(&check, from: 1200, to: 3000, startingAt: start, stops: [1000]) { _ in 60 }
        #expect(result == (0, 0))
    }

    @Test func gapAroundAStop() {
        // The laptop slept: a fix before the stop, the next one well past it.
        var check = StopCheck()
        _ = check.record(along: 700, speed: 50, stops: [1000], at: start)
        let result = check.record(along: 1700, speed: 80, stops: [1000], at: start.addingTimeInterval(40))
        #expect(result == (0, 0))
        let later = check.record(along: 1760, speed: 80, stops: [1000], at: start.addingTimeInterval(43))
        #expect(later == (0, 0))
    }

    @Test func sameFixTwice() {
        // Polled again before the router had a new fix: no gap, and the stop still counts.
        var check = StopCheck()
        _ = check.record(along: 300, speed: 40, stops: [1000], at: start)
        _ = check.record(along: 800, speed: 0, stops: [1000], at: start.addingTimeInterval(3))
        _ = check.record(along: 800, speed: 0, stops: [1000], at: start.addingTimeInterval(3))
        let result = run(&check, from: 820, to: 2000, startingAt: start.addingTimeInterval(6), stops: [1000]) { _ in 40 }
        #expect(result.stopped == 1)
    }
}
