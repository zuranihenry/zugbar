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

    /// Recorded on ICE 9 Hamburg → Basel, 10 Oct 2026, ten minutes before Frankfurt.
    @Test func realTrip() throws {
        let now = utc("2026-10-10T18:04:39Z")
        let status = try ICEPortal.parse(status: fixture("ice9_status"), trip: fixture("ice9_trip"), now: now)
        #expect(status.trainName == "ICE 9")
        #expect(status.destination == "Basel Bad Bf")
        #expect(status.vehicle?.hasPrefix("ICE 4 · Tz 9037") == true)
        #expect(status.wagonClass == 1)
        #expect(status.speed == 117)
        #expect(status.stops.count == 12)
        #expect(status.stops.prefix(6).allSatisfy { $0.passed })
        let next = try #require(status.nextStop)
        #expect(next.name == "Frankfurt(Main)Hbf")
        #expect(next.track == "8")
        // The portal's own figures: delays are cut off to whole minutes, not rounded.
        let delays = status.stops.prefix(6).map(\.delayMinutes)
        #expect(delays == [0, 0, 6, 1, 4, 2])
    }

    @Test func vehicleModels() {
        #expect(ICEVehicle.model(for: 304) == "ICE 3")
        #expect(ICEVehicle.model(for: 8012) == "ICE 3neo")
        #expect(ICEVehicle.model(for: 1523) == "ICE T")
        #expect(ICEVehicle.model(for: 42) == nil)
        #expect(ICEVehicle.describe(tzn: "Tz4651")?.hasPrefix("ICE 3 · Tz 4651") == true)
        #expect(ICEVehicle.describe(tzn: nil) == nil)
    }

    /// Seconds from a real ICE 9 trip: the portal showed Hannover +1 and Hamburg Dammtor on time.
    @Test func delaysCutOffToWholeMinutes() {
        let scheduled = utc("2026-10-10T15:49:00Z")
        let hannover = Stop(id: "8000152", name: "Hannover Hbf", scheduledArrival: scheduled, expectedArrival: scheduled.addingTimeInterval(118))
        let dammtor = Stop(id: "8002548", name: "Hamburg Dammtor", scheduledDeparture: scheduled, expectedDeparture: scheduled.addingTimeInterval(43))
        let early = Stop(id: "1", name: "Early", scheduledArrival: scheduled, expectedArrival: scheduled.addingTimeInterval(-50))
        #expect(hannover.delayMinutes == 1)
        #expect(dammtor.delayMinutes == 0)
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
