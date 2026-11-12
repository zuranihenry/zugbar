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

    @Test func vehicleFamilies() {
        #expect(ICEVehicle.family(series: "412", tzn: "Tz9018") == .ice4)
        #expect(ICEVehicle.family(series: "401", tzn: nil) == .ice1)
        #expect(ICEVehicle.family(series: "402", tzn: "Tz 215") == .ice1)
        #expect(ICEVehicle.family(series: "403", tzn: "Tz304") == .ice3)
        #expect(ICEVehicle.family(series: "406", tzn: "Tz4651") == .ice3)
        #expect(ICEVehicle.family(series: "411", tzn: "Tz1523") == .iceT)
        // Velaro D and ICE 3neo share a body that differs from the first ICE 3.
        #expect(ICEVehicle.family(series: "407", tzn: "Tz712") == .velaro)
        #expect(ICEVehicle.family(series: "408", tzn: "Tz8012") == .velaro)
        // The trainset number alone is enough.
        #expect(ICEVehicle.family(series: nil, tzn: "Tz9018") == .ice4)
        #expect(ICEVehicle.family(series: " ", tzn: "Tz4712") == .velaro)
        // Nothing rather than a guess: unknown series, unknown number, or the two disagreeing.
        #expect(ICEVehicle.family(series: nil, tzn: nil) == nil)
        #expect(ICEVehicle.family(series: "147", tzn: nil) == nil)
        #expect(ICEVehicle.family(series: "147", tzn: "Tz9018") == nil)
        #expect(ICEVehicle.family(series: nil, tzn: "Tz42") == nil)
        #expect(ICEVehicle.family(series: "412", tzn: "Tz304") == nil)
    }

    @Test func familiesFromPortals() throws {
        let ice = try ICEPortal.parse(status: DemoProvider.resource("demo_db_status"), trip: DemoProvider.resource("demo_db_trip"))
        #expect(ice.family == .ice4)
        #expect(try OEBBRailnet.parse(combined: DemoProvider.resource("demo_oebb"), now: Date()).family == .railjet)
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

    /// Off a train the site answers with nothing: it's then left alone, until another network is joined.
    @Test func leftAloneOffTheTrain() async {
        let asked = Tally()
        let memory = PortalMemory()
        let portal = Zugportal(loader: { _ in asked.add(); return Data() }, memory: memory)
        let start = utc("2099-01-01T09:00:00Z")
        for seconds in [0, 15, 30, 290] {
            await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(Double(seconds))) }
        }
        #expect(asked.count == 1)
        await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(301)) }
        #expect(asked.count == 2)
        memory.forget()
        await #expect(throws: ProviderError.self) { try await portal.fetch(now: start.addingTimeInterval(302)) }
        #expect(asked.count == 3)
    }

    /// On board the trip is asked for twice a minute, and a train without a router for its GPS once a minute.
    @Test func asksSparinglyOnBoard() async throws {
        let journeys = Tally(), routers = Tally()
        let journey = try fixture("zugportal_journey")
        let portal = Zugportal(loader: { url in
            guard url.host == "regio-guide.de" else { routers.add(); throw URLError(.cannotFindHost) }
            journeys.add()
            return journey
        }, memory: PortalMemory())
        let start = utc("2099-01-01T09:00:00Z")
        for seconds in stride(from: 0, to: 60, by: 3) {
            let status = try await portal.fetch(now: start.addingTimeInterval(Double(seconds)))
            #expect(status.trainName == "RE 80 (4711)")
        }
        #expect(journeys.count == 2)
        #expect(routers.count == 1)
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
        })
        let start = utc("2099-01-01T09:00:00Z")
        for seconds in stride(from: 0, to: 60, by: 3) {
            #expect(try await portal.fetch(now: start.addingTimeInterval(Double(seconds))).speed == 157)
        }
        #expect(trips.count == 1)
        #expect(positions.count == 7)
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
