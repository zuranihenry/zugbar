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
        #expect(status.wagonClass == 2)
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
