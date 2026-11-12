import Foundation
import Testing
@testable import ZugbarCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func utc(_ text: String) -> Date {
    try! Date(text, strategy: .iso8601)
}

struct ICEPortalTests {
    let now = utc("2026-06-12T16:20:00Z")

    func parse() throws -> TrainStatus {
        try ICEPortal.parse(
            status: DemoProvider.resource("demo_db_status"),
            trip: DemoProvider.resource("demo_db_trip"),
            now: now
        )
    }

    @Test func trip() throws {
        let status = try parse()
        #expect(status.trainName == "ICE 503")
        #expect(status.destination == "München Hbf")
        #expect(status.speed == 287)
        #expect(status.stops.count == 7)
        #expect(status.stops.prefix(4).allSatisfy { $0.passed })
        let next = try #require(status.nextStop)
        #expect(next.name == "Nürnberg Hbf")
        #expect(next.track == "8")
        #expect(next.delayMinutes == 4)
        #expect(try abs(#require(status.progress) - 330.0 / 603.0) < 0.001)
    }

    @Test func extras() throws {
        let status = try parse()
        #expect(status.vehicle == "ICE 4 · Tz 9018 „Freistaat Bayern“")
        #expect(status.internet == Internet(current: .good, next: .weak, nextChange: now.addingTimeInterval(240)))
    }

    @Test func hidesSpeedWithoutGPS() throws {
        let invalid = Data(#"{"speed":0,"gpsStatus":"INVALID"}"#.utf8)
        let status = try ICEPortal.parse(status: invalid, trip: DemoProvider.resource("demo_db_trip"))
        #expect(status.speed == nil)
        #expect(status.vehicle == nil)
        #expect(status.internet == nil)
    }

    @Test func connectivityCountdownAsString() throws {
        let json = Data(#"{"gpsStatus":"VALID","connectivity":{"currentState":"NO_INTERNET","nextState":"HIGH","remainingTimeSeconds":"60"}}"#.utf8)
        let status = try ICEPortal.parse(status: json, trip: DemoProvider.resource("demo_db_trip"), now: now)
        #expect(status.internet == Internet(current: .none, next: .good, nextChange: now.addingTimeInterval(60)))
    }

    @Test func keepsSpeedWithLastKnownPosition() throws {
        let tunnel = Data(#"{"speed":241.3,"gpsStatus":"LAST_KNOWN_POSITION","latitude":1,"longitude":1}"#.utf8)
        let status = try ICEPortal.parse(status: tunnel, trip: DemoProvider.resource("demo_db_trip"))
        #expect(status.speed == 241)
        #expect(status.position == nil)
    }

    @Test func negativeSpeedIsNoSpeed() throws {
        let json = Data(#"{"speed":-1,"gpsStatus":"VALID","latitude":1,"longitude":1}"#.utf8)
        let status = try ICEPortal.parse(status: json, trip: DemoProvider.resource("demo_db_trip"))
        #expect(status.speed == nil)
        #expect(status.position == Coordinate(latitude: 1, longitude: 1))
    }

    @Test func internetFromTopLevelLevel() throws {
        func internet(_ level: String) throws -> Internet? {
            let json = Data(#"{"gpsStatus":"VALID","internet":"\#(level)"}"#.utf8)
            return try ICEPortal.parse(status: json, trip: DemoProvider.resource("demo_db_trip"), now: now).internet
        }
        #expect(try internet("HIGH") == Internet(current: .good))
        #expect(try internet("MIDDLE") == Internet(current: .weak))
        #expect(try internet("OFFLINE") == Internet(current: .none))
        #expect(try internet("SOMETHING") == nil)
    }

    @Test func connectivityBlockWinsOverTopLevelLevel() throws {
        let json = Data(#"{"gpsStatus":"VALID","internet":"HIGH","connectivity":{"currentState":"NO_INTERNET","nextState":"HIGH","remainingTimeSeconds":60}}"#.utf8)
        let status = try ICEPortal.parse(status: json, trip: DemoProvider.resource("demo_db_trip"), now: now)
        #expect(status.internet == Internet(current: .none, next: .good, nextChange: now.addingTimeInterval(60)))
    }

    /// Progress on a made-up run: A at 0 km, B at 100, C at 200, D at 400.
    func progress(_ actualPosition: Int, last actualLast: String?, moved: Int?) throws -> Double? {
        let stops = [("A", 0), ("B", 100_000), ("C", 200_000), ("D", 400_000)]
            .map { #"{"station":{"evaNr":"\#($0.0)","name":"\#($0.0)"},"info":{"distanceFromStart":\#($0.1)}}"# }
        let last = actualLast.map { #""\#($0)""# } ?? "null"
        let trip = #"""
        {"trip":{"actualPosition":\#(actualPosition),"distanceFromLastStop":\#(moved.map(String.init) ?? "null"),
        "totalDistance":400000,"stopInfo":{"actualLast":\#(last)},"stops":[\#(stops.joined(separator: ","))]}}
        """#
        return try ICEPortal.parse(status: Data(#"{"gpsStatus":"VALID"}"#.utf8), trip: Data(trip.utf8), now: now).progress
    }

    @Test func progressCountsOnBetweenStops() throws {
        // Between B and C, while actualPosition still says B.
        #expect(try progress(100_000, last: "B", moved: 50_000) == 0.375)
        // Standing at C before the last stop moves on to it: no step back.
        #expect(try progress(200_000, last: "B", moved: 99_990) == 0.5)
        // Just left C, written with the suffix some portals add.
        #expect(try progress(200_000, last: "C_00", moved: 400) == 200_400.0 / 400_000)
        // Never past the next stop.
        #expect(try progress(100_000, last: "B", moved: 150_000) == 0.5)
        // Without the count, the stop last reached.
        #expect(try progress(100_000, last: nil, moved: nil) == 0.25)
    }

    /// A track changed before Zugbar connected shows up as actual and scheduled differing; empty strings mean none.
    @Test func trackChangeAgainstTimetable() throws {
        let trip = Data(#"""
        {"trip":{"trainType":"ICE","vzn":"1","stops":[
          {"station":{"evaNr":"1","name":"Ahornstadt Hbf"},"track":{"scheduled":"5","actual":"7"}},
          {"station":{"evaNr":"2","name":"Buchenweiler"},"track":{"scheduled":"4","actual":"4"}},
          {"station":{"evaNr":"3","name":"Eibental"},"track":{"scheduled":"","actual":"3"}},
          {"station":{"evaNr":"4","name":"Lindenmoor"},"track":{"scheduled":"2","actual":""}},
          {"station":{"evaNr":"5","name":"Ulmenhof"}}
        ]}}
        """#.utf8)
        let stops = try ICEPortal.parse(status: Data(#"{"gpsStatus":"INVALID"}"#.utf8), trip: trip).stops
        #expect(stops.map(\.track) == ["7", "4", "3", "2", nil])
        #expect(stops.map(\.scheduledTrack) == ["5", "4", nil, "2", nil])
        #expect(stops.map(\.trackChanged) == [true, false, false, false, false])
    }

    @Test func demoTrainDrivesAlongItsTrack() async throws {
        let status = try await DemoProvider().fetch()
        let route = try #require(status.route)
        let now = try #require(status.position)
        let later = try #require(DemoProvider.drive(status, along: route, at: Date().addingTimeInterval(60)))
        // On the track, and about a minute's worth further along it.
        #expect(TrackLimit(maxspeed: 0, nodes: route.points).distance(to: now) < 0.01)
        let moved = route.distance(of: later.0) - route.distance(of: now)
        #expect(moved > 1_000 && moved < 6_000)
        #expect(later.1 > 80)
    }

    @Test func vehicleModels() {
        #expect(ICEVehicle.model(for: 304) == "ICE 3")
        #expect(ICEVehicle.model(for: 8012) == "ICE 3neo")
        #expect(ICEVehicle.model(for: 1523) == "ICE T")
        #expect(ICEVehicle.model(for: 42) == nil)
        #expect(ICEVehicle.describe(tzn: "Tz4651")?.hasPrefix("ICE 3 · Tz 4651") == true)
        #expect(ICEVehicle.describe(tzn: nil) == nil)
    }

    /// Like the portals: 1:58 late is +1, 0:43 late is on time.
    @Test func delaysCutOffToWholeMinutes() {
        let scheduled = utc("2026-06-12T16:00:00Z")
        let late = Stop(id: "1", name: "A", scheduledArrival: scheduled, expectedArrival: scheduled.addingTimeInterval(118))
        let slightly = Stop(id: "2", name: "B", scheduledDeparture: scheduled, expectedDeparture: scheduled.addingTimeInterval(43))
        let early = Stop(id: "3", name: "C", scheduledArrival: scheduled, expectedArrival: scheduled.addingTimeInterval(-50))
        #expect(late.delayMinutes == 1)
        #expect(slightly.delayMinutes == 0)
        #expect(early.delayMinutes == 0)
    }
}

struct OEBBRailnetTests {
    @Test func trip() throws {
        let status = try OEBBRailnet.parse(combined: DemoProvider.resource("demo_oebb"), now: vienna(10, 30))
        #expect(status.trainName == "RJX 542")
        #expect(status.destination == "Salzburg Hbf")
        #expect(status.speed == 198)
        let next = try #require(status.nextStop)
        #expect(next.name == "Linz Hbf")
        #expect(next.track == "6A-F")
        #expect(next.delayMinutes == 5)
        #expect(next.arrival == vienna(10, 49))
        #expect(status.stops.prefix(2).allSatisfy { $0.passed })
    }

    @Test func clockRollsOverMidnight() {
        let clock = OEBBRailnet.Clock(now: vienna(23, 50))
        #expect(clock.date("00:10") == vienna(23, 50).addingTimeInterval(20 * 60))
        #expect(clock.date("") == nil)
        #expect(clock.date("nope") == nil)
    }

    /// When clocks go back, 03:00 summer time becomes 02:00 winter time and the hour in between comes twice.
    @Test func clockPicksTheCloserOfTheRepeatedHour() throws {
        let fallBack = try #require(TimeZone(identifier: "Europe/Vienna")!.nextDaylightSavingTimeTransition(after: vienna(0, 0)))
        let summer = OEBBRailnet.Clock(now: fallBack.addingTimeInterval(-15 * 60)) // 02:45 summer time
        #expect(summer.date("02:50") == fallBack.addingTimeInterval(-10 * 60))
        #expect(summer.date("02:40") == fallBack.addingTimeInterval(-20 * 60))
        let winter = OEBBRailnet.Clock(now: fallBack.addingTimeInterval(45 * 60)) // 02:45 winter time
        #expect(winter.date("02:50") == fallBack.addingTimeInterval(50 * 60))
        #expect(winter.date("02:40") == fallBack.addingTimeInterval(40 * 60))
        #expect(winter.date("03:10") == fallBack.addingTimeInterval(70 * 60))
        #expect(winter.date("01:50") == fallBack.addingTimeInterval(-70 * 60))
    }

    private func vienna(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return calendar.date(from: DateComponents(year: 2026, month: 6, day: 12, hour: hour, minute: minute))!
    }
}

struct SNCFInouiTests {
    @Test func trip() throws {
        let status = try SNCFInoui.parse(details: fixture("sncf_details"), gps: fixture("sncf_gps"))
        #expect(status.trainName == "TGV INOUI 6107")
        #expect(status.destination == "Marseille Saint-Charles")
        #expect(status.speed == 300)
        #expect(status.stops.prefix(2).allSatisfy { $0.passed })
        let next = try #require(status.nextStop)
        #expect(next.name == "Avignon TGV")
        #expect(next.delayMinutes == 4)
        #expect(next.departure == utc("2026-06-12T11:17:00Z"))
        #expect(status.stops.first?.track == "K")
        #expect(status.stops[1].track == nil)
    }

    @Test func worksWithoutGPS() throws {
        let status = try SNCFInoui.parse(details: fixture("sncf_details"), gps: nil)
        #expect(status.speed == nil)
    }
}

struct ZugportalTests {
    @Test func trip() throws {
        let status = try Zugportal.parse(journey: fixture("zugportal_journey"))
        #expect(status.trainName == "RE 80 (4711)")
        #expect(status.trainNumber?.number == "4711")
        #expect(status.destination == "Neustadt (Beispiel) Hbf")
        #expect(status.stops.map(\.passed) == [true, true, false, false, false])
        let next = try #require(status.nextStop)
        #expect(next.name == "Mittelfeld")
        #expect(next.id == "9000003")
        #expect(next.delayMinutes == 2)
        #expect(next.arrival == utc("2099-01-01T09:17:30Z"))
        #expect(next.track == "4")
        #expect(next.trackChanged)
        #expect(next.delayReasons == ["Verzögerungen im Betriebsablauf"])
        #expect(next.coordinate == Coordinate(latitude: 50.1, longitude: 8.1))
        #expect(status.stops[3].cancelled)
        // Only the timetable: no forecast made up from it.
        #expect(status.stops[3].expectedArrival == nil)
        // The last stop's times come in UTC with milliseconds.
        #expect(status.stops[4].scheduledArrival == utc("2099-01-01T09:30:00Z"))
        #expect(status.stops[4].expectedArrival == nil)
        #expect(status.stops[4].scheduledDeparture == nil)
    }

    /// The portal itself knows neither speed nor position.
    @Test func speedOnlyFromTheRouter() throws {
        let without = try Zugportal.parse(journey: fixture("zugportal_journey"))
        #expect(without.speed == nil)
        #expect(without.position == nil)
        let place = Coordinate(latitude: 50.07, longitude: 8.07)
        let fresh = try Zugportal.parse(journey: fixture("zugportal_journey"), fix: .init(coordinate: place, speed: 118, heading: 40, age: 2))
        #expect(fresh.speed == 118)
        #expect(fresh.position == place)
        let stale = try Zugportal.parse(journey: fixture("zugportal_journey"), fix: .init(coordinate: place, speed: 118, heading: 40, age: 90))
        #expect(stale.speed == nil)
        #expect(stale.position == nil)
    }

    @Test func missingFields() throws {
        let json = Data("""
        {"stops": [
            {"station": {"name": "A"}, "departureTime": {"target": "2099-01-01T10:00:00+01:00", "timeType": "REAL"}},
            {"station": {"evaNo": "9000009"}},
            {"station": {"name": "B", "evaNo": "9000002"}, "track": {"target": "", "prediction": ""},
             "arrivalTime": {"target": "2099-01-01T10:10:00+01:00", "predicted": "2099-01-01T10:12:00.000Z"}}
        ]}
        """.utf8)
        let status = try Zugportal.parse(journey: json)
        #expect(status.trainName == nil)
        #expect(status.stops.map(\.name) == ["A", "B"])
        #expect(status.stops[0].id == "A")
        #expect(status.stops[0].scheduledDeparture == utc("2099-01-01T09:00:00Z"))
        #expect(status.stops[0].passed)
        #expect(status.nextStop?.name == "B")
        #expect(status.stops[1].track == nil)
        #expect(status.stops[1].coordinate == nil)
        #expect(status.stops[1].expectedArrival == utc("2099-01-01T10:12:00Z"))
        #expect(throws: (any Error).self) { try Zugportal.parse(journey: Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try Zugportal.parse(journey: Data()) }
    }

    /// A number no train has, as text or too large for an Int, is left out instead of trapping.
    @Test func trainNumberOutOfRange() throws {
        for number in [#""1e999""#, "1e30", #""nan""#, "-5", "0", #""x""#, "null"] {
            let json = Data(#"{"name": "RE 80", "no": \#(number), "stops": [{"station": {"name": "A"}}]}"#.utf8)
            #expect(try Zugportal.parse(journey: json).trainName == "RE 80")
        }
        let text = Data(#"{"name": "RE 80", "no": "4711", "stops": [{"station": {"name": "A"}}]}"#.utf8)
        #expect(try Zugportal.parse(journey: text).trainName == "RE 80 (4711)")
    }

    /// One field of another type than expected only costs that field.
    @Test func otherTypes() throws {
        let json = Data(#"""
        {"name": 80, "category": "RE", "no": "4711", "hims": "none", "stops": [
            {"status": 1, "canceled": "true", "station": {"evaNo": 9000001, "name": "A", "position": "here"},
             "track": {"target": 3, "prediction": 4}, "messages": {"text": "x"},
             "departureTime": {"target": 12, "targetTimeInMs": "4070941200000", "timeType": 7}},
            "not a stop",
            {"canceled": 0, "station": {"evaNo": "9000002", "name": "B", "position": {"latitude": "50.1", "longitude": 8.1}},
             "track": 5, "arrivalTime": "soon", "messages": [3, {"type": "CUSTOMER_REASON", "text": "Bauarbeiten", "textShort": []}]}
        ]}
        """#.utf8)
        let status = try Zugportal.parse(journey: json)
        #expect(status.trainName == "80 (4711)")
        #expect(status.stops.map(\.id) == ["9000001", "9000002"])
        #expect(status.stops[0].cancelled)
        #expect(status.stops[0].track == "4")
        #expect(status.stops[0].scheduledTrack == "3")
        #expect(status.stops[0].coordinate == nil)
        #expect(status.stops[0].scheduledDeparture == utc("2099-01-01T09:00:00Z"))
        #expect(!status.stops[1].cancelled)
        #expect(status.stops[1].track == nil)
        #expect(status.stops[1].arrival == nil)
        #expect(status.stops[1].coordinate == Coordinate(latitude: 50.1, longitude: 8.1))
        #expect(status.stops[1].delayReasons == ["Bauarbeiten"])
        #expect(throws: (any Error).self) { try Zugportal.parse(journey: Data(#"{"stops": "none"}"#.utf8)) }
    }

    /// Whatever comes back that isn't a trip, the site is left alone: for a minute, then two, four, up to half an
    /// hour, or until another network is joined.
    @Test(arguments: ["nothing", "page", "other JSON", "404", "timeout"])
    func leftAloneOffTheTrain(answer: String) async {
        let asked = Tally()
        let memory = PortalMemory()
        let portal = Zugportal(loader: { _ in
            asked.add()
            switch answer {
            case "nothing": return Data()
            case "page": return Data("<!doctype html><html></html>".utf8)
            case "other JSON": return Data(#"{"error": "no journey"}"#.utf8)
            case "404": throw ProviderError.badStatus(404)
            default: throw URLError(.timedOut)
            }
        }, router: { _ in throw URLError(.cannotFindHost) }, memory: memory)
        let start = utc("2099-01-01T09:00:00Z")
        func probe(_ seconds: Double) async {
            await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(seconds)) }
        }
        // Both hosts once, then nothing while paused.
        for seconds in [0.0, 15, 30, 59] { await probe(seconds) }
        #expect(asked.count == 2)
        await probe(61)
        #expect(asked.count == 4)
        // The second pause is twice as long.
        await probe(61 + 119)
        #expect(asked.count == 4)
        await probe(61 + 121)
        #expect(asked.count == 6)
        // Never longer than half an hour.
        var at = 61.0 + 121
        for _ in 0..<8 {
            at += 30 * 60 + 1
            await probe(at)
        }
        #expect(asked.count == 6 + 8 * 2)
        await probe(at + 29 * 60)
        #expect(asked.count == 6 + 8 * 2)
        memory.forget()
        await probe(at + 29 * 60 + 1)
        #expect(asked.count == 6 + 8 * 2 + 2)
    }

    /// On board the trip is asked for twice a minute from the host that has it, and a train without a router for
    /// its GPS once a minute.
    @Test func asksSparinglyOnBoard() async throws {
        let journeys = Tally(), others = Tally(), routers = Tally()
        let journey = try fixture("zugportal_journey")
        let portal = Zugportal(loader: { url in
            guard url.host == "regio-guide.de" else { others.add(); throw ProviderError.badStatus(301) }
            journeys.add()
            return journey
        }, router: { _ in routers.add(); throw URLError(.cannotFindHost) }, memory: PortalMemory())
        let start = utc("2099-01-01T09:00:00Z")
        for seconds in stride(from: 0, to: 60, by: 3) {
            let status = try await portal.fetch(now: start.addingTimeInterval(Double(seconds)))
            #expect(status.trainName == "RE 80 (4711)")
        }
        #expect(journeys.count == 2)
        #expect(others.count == 1)
        #expect(routers.count == 1)
    }

    /// A gap in a trip that just answered is the Wi-Fi: asked again on the next poll. Later it's the trip's end.
    @Test func aGapMidTripIsNotAPause() async throws {
        let asked = Tally(), down = Tally()
        let journey = try fixture("zugportal_journey")
        let portal = Zugportal(loader: { _ in
            asked.add()
            if down.count > 0 { throw URLError(.networkConnectionLost) }
            return journey
        }, router: { _ in throw URLError(.cannotFindHost) }, memory: PortalMemory())
        let start = utc("2099-01-01T09:00:00Z")
        _ = try await portal.fetch(now: start)
        let before = asked.count
        down.add()
        await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(40)) }
        await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(43)) }
        #expect(asked.count == before + 1 + 2)
        await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(130)) }
        let paused = asked.count
        await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(140)) }
        #expect(asked.count == paused)
    }
}

struct CDWiFiTests {
    @Test func trip() throws {
        let status = try CDWiFi.parse(trip: fixture("cd_trip"), realtime: fixture("cd_realtime"))
        #expect(status.trainName == "RJ 256")
        #expect(status.destination == "Horní Pole hl.n.")
        #expect(status.speed == 157)
        #expect(status.position == Coordinate(latitude: 49.35, longitude: 16.15))
        #expect(status.stops.map(\.passed) == [true, true, false, false])
        let next = try #require(status.nextStop)
        #expect(next.name == "Dlouhá Louka")
        #expect(next.id == "9100003")
        #expect(next.scheduledArrival == utc("2099-01-01T09:50:00Z"))
        #expect(next.scheduledDeparture == utc("2099-01-01T09:52:00Z"))
        // The portal has the timetable only.
        #expect(next.expectedArrival == nil)
        #expect(next.delayMinutes == nil)
        #expect(next.track == nil)
        #expect(status.stops[0].scheduledArrival == nil)
        // An offset without a colon, as older portals write it.
        #expect(status.stops[3].scheduledArrival == utc("2099-01-01T10:35:00Z"))
    }

    @Test func worksWithoutSpeedData() throws {
        let none = try CDWiFi.parse(trip: fixture("cd_trip"), realtime: nil)
        #expect(none.speed == nil)
        #expect(none.position == nil)
        #expect(none.nextStop?.name == "Dlouhá Louka")
        // No fix: a speed next to empty coordinates isn't one.
        let noFix = try CDWiFi.parse(trip: fixture("cd_trip"), realtime: Data(#"{"gpsLat": null, "gpsLng": null, "speed": 0, "delay": null}"#.utf8))
        #expect(noFix.speed == nil)
        let zero = try CDWiFi.parse(trip: fixture("cd_trip"), realtime: Data(#"{"gpsLat": 0, "gpsLng": 0, "speed": 0}"#.utf8))
        #expect(zero.speed == nil)
        let text = try CDWiFi.parse(trip: fixture("cd_trip"), realtime: Data(#"{"gpsLat": "49.35", "gpsLng": "16.15", "speed": "80"}"#.utf8))
        #expect(text.speed == 80)
        let page = try CDWiFi.parse(trip: fixture("cd_trip"), realtime: Data("<html>".utf8))
        #expect(page.speed == nil)
    }

    @Test func missingFields() throws {
        let json = Data(#"""
        {"id": null, "name": null, "line": null, "connexionTimes": [
            {"timeArrival": null, "timeDeparture": "nope", "station": {"name": "A"}},
            {"station": {"id": 9100009}},
            {"timeArrival": "2099-01-01T11:00:00+01:00", "state": 0, "station": {"id": "x7", "name": "B"}}
        ]}
        """#.utf8)
        let status = try CDWiFi.parse(trip: json, realtime: nil)
        #expect(status.trainName == nil)
        #expect(status.stops.map(\.id) == ["A", "x7"])
        #expect(status.stops[0].scheduledDeparture == nil)
        #expect(status.stops[0].coordinate == nil)
        #expect(status.nextStop?.name == "A")
        let typed = Data(#"""
        {"id": "x", "name": 256, "connexionTimes": [
            {"timeArrival": 5, "timeDeparture": "2099-01-01T10:00:00+0100", "state": "4",
             "station": {"id": "9100001", "name": "A", "gpsLat": "49.0", "gpsLng": 16, "city": 3}},
            7,
            {"timeArrival": "2099-01-01T11:00:00+01:00", "state": {}, "station": {"id": 9100002, "name": "B", "gpsLat": []}}
        ]}
        """#.utf8)
        let other = try CDWiFi.parse(trip: typed, realtime: Data(#"{"gpsLat": 49.5, "gpsLng": 16.2, "speed": [1]}"#.utf8))
        #expect(other.trainName == "256")
        #expect(other.stops.map(\.id) == ["9100001", "9100002"])
        #expect(other.stops.map(\.passed) == [true, false])
        #expect(other.stops[0].scheduledArrival == nil)
        #expect(other.stops[0].scheduledDeparture == utc("2099-01-01T09:00:00Z"))
        #expect(other.stops[0].coordinate == Coordinate(latitude: 49, longitude: 16))
        #expect(other.stops[1].coordinate == nil)
        #expect(other.speed == nil)
        #expect(other.position == Coordinate(latitude: 49.5, longitude: 16.2))
        #expect(CDWiFi.trainName("Ex 143") == "Ex 143")
        #expect(CDWiFi.trainName("  ") == nil)
        // No trip loaded: nothing to show.
        #expect(throws: (any Error).self) {
            try CDWiFi.parse(trip: Data(#"{"id": null, "name": null, "connexionTimes": []}"#.utf8), realtime: fixture("cd_realtime"))
        }
    }

    /// The timetable once a minute, the position as often as the portal renews it.
    @Test func asksSparingly() async throws {
        let trips = Tally(), positions = Tally()
        let trip = try fixture("cd_trip"), realtime = try fixture("cd_realtime")
        let portal = CDWiFi(loader: { url in
            if url == CDWiFi.tripURL { trips.add(); return trip }
            positions.add()
            return realtime
        }, memory: PortalMemory())
        let start = utc("2099-01-01T09:00:00Z")
        for seconds in stride(from: 0, to: 60, by: 3) {
            #expect(try await portal.fetch(now: start.addingTimeInterval(Double(seconds))).speed == 157)
        }
        #expect(trips.count == 1)
        #expect(positions.count == 7)
    }

    /// Without a trip in the answer the portal is left alone, also by the next probe, which is a new provider.
    @Test(arguments: ["no host", "page", "no trip"])
    func leftAloneOffTheTrain(answer: String) async {
        let asked = Tally()
        let memory = PortalMemory()
        let loader: DataLoader = { url in
            if url == CDWiFi.tripURL { asked.add() }
            switch answer {
            case "no host": throw URLError(.cannotFindHost)
            case "page": return Data("<html>Sign in</html>".utf8)
            default: return Data(#"{"id": null, "name": null, "connexionTimes": []}"#.utf8)
            }
        }
        let start = utc("2099-01-01T09:00:00Z")
        for seconds in [0.0, 15, 45, 61, 75, 181] {
            await #expect(throws: (any Error).self) {
                try await CDWiFi(loader: loader, memory: memory).fetch(now: start.addingTimeInterval(seconds))
            }
        }
        // At 0 s, after the first minute's pause at 61 s, and after the two minutes' at 181 s.
        #expect(asked.count == 3)
    }
}

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

struct DetectionTests {
    @Test func onlyTheReachablePortalAnswers() async {
        let loader: DataLoader = { url in
            switch url.path {
            case "/api1/rs/status": try DemoProvider.resource("demo_db_status")
            case "/api1/rs/tripInfo/trip": try DemoProvider.resource("demo_db_trip")
            default: throw URLError(.cannotFindHost)
            }
        }
        let answering = await withTaskGroup(of: String?.self) { group in
            for provider in Providers.onBoard(loader: loader) {
                group.addTask { (try? await provider.fetch())?.provider }
            }
            return await group.reduce(into: [String]()) { if let name = $1 { $0.append(name) } }
        }
        #expect(answering == ["Deutsche Bahn"])
    }
}

struct IcomeraTests {
    @Test func position() throws {
        let data = Data("""
        ({
            "version":"1.11",
            "time":"1700000000",
            "age":"1",
            "latitude":"45.5",
            "longitude":"7.25",
            "altitude":"120.0",
            "speed":"25.0",
            "cmg":"42.5",
            "satellites":"12",
            "mode":"3"
        });
        """.utf8)
        let fix = try Icomera.parse(data)
        #expect(fix.coordinate == Coordinate(latitude: 45.5, longitude: 7.25))
        #expect(fix.speed == 90)
        #expect(fix.age == 1)
    }

    @Test func noFix() {
        let data = Data(#"({"latitude":"45.5","longitude":"7.25","speed":"0.0","mode":"1"});"#.utf8)
        #expect(throws: ProviderError.self) { try Icomera.parse(data) }
        #expect(throws: ProviderError.self) { try Icomera.parse(Data(#"({"latitude":"0","longitude":"0"});"#.utf8)) }
        #expect(throws: ProviderError.self) { try Icomera.parse(Data("<html></html>".utf8)) }
        #expect(throws: ProviderError.self) { try Icomera.parse(Data(#"({"latitude":"nan","longitude":"7.25"});"#.utf8)) }
        #expect(throws: ProviderError.self) { try Icomera.parse(Data(#"({"latitude":"91","longitude":"7.25"});"#.utf8)) }
    }

    @Test func oddNumbers() throws {
        for speed in ["nan", "inf", "-inf", "1e300", ""] {
            let fix = try Icomera.parse(Data(#"({"latitude":"45.5","longitude":"7.25","speed":"\#(speed)","cmg":"nan","age":"-3","mode":"3"});"#.utf8))
            #expect(fix.speed >= 0 && fix.speed <= 540)
            #expect(fix.heading == nil)
            #expect(fix.age == 0)
        }
    }
}
