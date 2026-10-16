import Foundation
import Testing
@testable import ZugbarCore

struct BoardedConnectionTests {
    let now = utc("2026-03-02T12:00:00Z")

    var plan: JourneyPlan {
        let connection = Connection(tripID: "y", name: "ICE 902", headsign: nil, station: "Brückenfeld",
                                    scheduledDeparture: now.addingTimeInterval(-30 * 60), expectedDeparture: nil, track: nil,
                                    finalStop: "Endhausen")
        return JourneyPlan(trainName: "ICE 901", destinationStopID: "3-b", connection: connection)
    }

    @Test func onTheConnection() {
        #expect(Handover.boardedConnection(plan: plan, trainName: "ICE902", now: now)?.tripID == "y")
        #expect(Handover.boardedConnection(plan: plan, trainName: "ICE 901", now: now) == nil)
        #expect(Handover.boardedConnection(plan: plan, trainName: "RE 7", now: now) == nil)
        #expect(Handover.boardedConnection(plan: plan, trainName: "ICE 902", now: now.addingTimeInterval(7 * 3600)) == nil)
    }
}

struct DelayBaselineTests {
    let start = utc("2026-03-02T12:00:00Z")

    func status(delay: Int) -> TrainStatus {
        TrainStatus(provider: "DB", trainName: "ICE 901", stops: [
            Stop(id: "a", name: "Altstadt", scheduledDeparture: start, passed: true),
            Stop(id: "b", name: "Brückenfeld", scheduledArrival: start.addingTimeInterval(3600),
                 expectedArrival: start.addingTimeInterval(3600 + Double(delay) * 60)),
        ])
    }

    @Test func growingAMinuteAtATime() {
        let plan = JourneyPlan(trainName: "ICE 901", destinationStopID: "b")
        var delays: [String: Int] = [:]
        var events: [JourneyEvent] = []
        for minute in 0..<6 {
            events += JourneyWatcher.events(
                old: status(delay: minute), oldTime: start, oldConnection: nil,
                new: status(delay: minute + 1), newTime: start.addingTimeInterval(30), newConnection: nil,
                plan: plan, delays: &delays
            )
        }
        #expect(events == [.delayChanged(stop: "Brückenfeld", from: 0, to: 3), .delayChanged(stop: "Brückenfeld", from: 3, to: 6)])
    }
}

struct TripIdleTests {
    let start = utc("2026-03-02T12:00:00Z")

    func status(_ km: Double, provider: String = "DB") -> TrainStatus {
        TrainStatus(provider: provider, trainName: "ICE 901", speed: 200, stops: [
            Stop(id: "a", name: "Altstadt", passed: true, coordinate: Coordinate(latitude: 45, longitude: 7)),
            Stop(id: "b", name: "Brückenfeld", coordinate: Coordinate(latitude: 45.5, longitude: 7)),
        ], position: Coordinate(latitude: 45 + km / 111.2, longitude: 7))
    }

    @Test func portalGapIsOneTrip() {
        var recorder = TripRecorder()
        var trips: [Trip] = []
        func add(_ trip: Trip?) { if let trip { trips.append(trip) } }
        add(recorder.update(status(0), at: start))
        add(recorder.update(status(10), at: start.addingTimeInterval(300)))
        // The portal drops; the same train followed online meanwhile.
        add(recorder.update(status(20, provider: "Transitous"), at: start.addingTimeInterval(600)))
        add(recorder.update(status(30), at: start.addingTimeInterval(900)))
        #expect(trips.isEmpty)
        add(recorder.finish())
        #expect(trips.count == 1)
        #expect(trips.first.map { abs($0.distance - 30) < 0.5 } == true)
    }

    @Test func idleTripEnds() {
        var recorder = TripRecorder()
        _ = recorder.update(status(0), at: start)
        _ = recorder.update(status(20), at: start.addingTimeInterval(600))
        #expect(recorder.finishIfIdle(at: start.addingTimeInterval(1500)) == nil)
        #expect(recorder.finishIfIdle(at: start.addingTimeInterval(1900)) != nil)
    }
}

struct OEBBCurrentFormatTests {
    let json = """
    {"trainType":"RJX","tripNumber":"960","destination":{"all":"Endhausen","de":"Endhausen"},
     "nextStation":{"id":"2"},
     "latestStatus":{"dateTime":"2026-03-02T21:30:00+01:00","speed":182.4,"gpsPosition":{"latitude":"47.5","longitude":"13.1"}},
     "stations":[
      {"id":"1","name":{"all":"Altstadt"},"track":{"all":"3"},"departure":{"scheduled":"20:00","forecast":"20:05"}},
      {"id":"2","name":{"all":"Brückenfeld"},"track":{"de":"5"},"arrival":{"scheduled":"22:00","forecast":"23:40"},
       "departure":{"scheduled":"22:02","forecast":"23:42"}},
      {"id":"3","name":{"all":"Coswig Süd"},"arrival":{"scheduled":"02:30"},"departure":{"scheduled":"02:35"}},
      {"id":"4","name":{"all":"Endhausen"},"arrival":{"scheduled":"10:30","forecast":"10:40"}}
     ]}
    """

    @Test func parses() throws {
        let status = try OEBBRailnet.parse(combined: Data(json.utf8), now: utc("2026-03-02T20:31:00Z"))
        #expect(status.trainName == "RJX 960")
        #expect(status.destination == "Endhausen")
        #expect(status.speed == 182)
        #expect(status.position == Coordinate(latitude: 47.5, longitude: 13.1))
        #expect(status.nextStopID == "2")
        #expect(status.stops.map(\.passed) == [true, false, false, false])
        #expect(status.stops[1].track == "5")
        #expect(status.stops[1].delayMinutes == 100)
        // A night train: the later stops are on the next day, the earlier one on the same.
        #expect(status.stops[0].scheduledDeparture == utc("2026-03-02T19:00:00Z"))
        #expect(status.stops[2].scheduledArrival == utc("2026-03-03T01:30:00Z"))
        #expect(status.stops[3].scheduledArrival == utc("2026-03-03T09:30:00Z"))
        #expect(status.stops[3].expectedArrival == utc("2026-03-03T09:40:00Z"))
    }

    @Test func oldFormatStillWorks() throws {
        let status = try OEBBRailnet.parse(combined: DemoProvider.resource("demo_oebb"), now: Date())
        #expect(!status.stops.isEmpty)
    }

    @Test func noStations() {
        #expect(throws: (any Error).self) { try OEBBRailnet.parse(combined: Data("{}".utf8), now: Date()) }
    }
}

struct QueryTests {
    @Test func plusIsEncoded() {
        var url = URL(string: "https://example.test/api")!
        url.appendQuery([URLQueryItem(name: "tripId", value: "a+b c")])
        #expect(url.absoluteString == "https://example.test/api?tripId=a%2Bb%20c")
    }

    @Test func foundTrips() async {
        let cache = FoundTrips()
        let now = utc("2026-03-02T12:00:00Z")
        #expect(await cache.lookup("ICE 901", at: now) == nil)
        await cache.store("ICE 901", tripID: "t1", until: now.addingTimeInterval(3600))
        #expect(await cache.lookup("ice901", at: now) == .found("t1"))
        #expect(await cache.lookup("ICE 901", at: now.addingTimeInterval(3601)) == nil)
        await cache.notRunning("RE 5", at: now)
        #expect(await cache.lookup("RE 5", at: now.addingTimeInterval(60)) == .notRunning)
        #expect(await cache.lookup("RE 5", at: now.addingTimeInterval(301)) == nil)
        // Missing again waits longer.
        await cache.notRunning("RE 5", at: now)
        #expect(await cache.lookup("RE 5", at: now.addingTimeInterval(301)) == .notRunning)
    }

    @Test func prefersTheLiveCopy() throws {
        let data = Data("""
        [{"mode":"HIGHSPEED_RAIL","realTime":false,"trips":[{"tripId":"planned","displayName":"ICE 901"}]},
         {"mode":"HIGHSPEED_RAIL","realTime":true,"trips":[{"tripId":"live","displayName":"ICE 901"}]}]
        """.utf8)
        #expect(try Transitous.matchTrip(in: data, query: "ICE 901")?.tripID == "live")
    }

    @Test func stationTowns() throws {
        let data = Data("""
        [{"id":"x1","name":"Hauptbahnhof Süd","modes":["REGIONAL_RAIL"],"areas":[{"name":"Altstadt","default":true}]},
         {"id":"x2","name":"Dornstadt","modes":["REGIONAL_RAIL"],"areas":[{"name":"Dornstadt","default":true}]}]
        """.utf8)
        let names = try TransitousClient.parseStations(data).map(\.name)
        #expect(names == ["Altstadt Hauptbahnhof Süd", "Dornstadt"])
    }
}

struct ShortSectionTests {
    @Test func twoSamplesStillGetATopSpeed() throws {
        let profile = try #require(SpeedProfile(length: 300, limits: [80, 80], duration: 60, kind: .regional))
        let middle = profile.state(after: 30)
        #expect(middle.speed > 0)
        #expect(profile.state(after: 60).distance > 290)
    }
}

struct CoordinateTests {
    @Test func oddValues() {
        #expect(Coordinate(.nan, 7) == nil)
        #expect(Coordinate(45, .infinity) == nil)
        #expect(Coordinate(91, 7) == nil)
        #expect(Coordinate(0, 0) == nil)
        #expect(Coordinate(45, 7) != nil)
    }
}
