import Foundation
import Testing
@testable import ZugbarCore

struct TransitousTests {
    @Test func matchesTrainNames() throws {
        let data = try fixture("transitous_map_trips")
        let id = "20261005_18:16_de-DELFI_3426062749"
        #expect(try Transitous.matchTrip(in: data, query: "ICE 777") == id)
        #expect(try Transitous.matchTrip(in: data, query: "ice777") == id)
        #expect(try Transitous.matchTrip(in: data, query: "777") == id)
        #expect(try Transitous.matchTrip(in: data, query: "ICE 591") == nil)
        #expect(try Transitous.matchTrip(in: data, query: "CAG-POZ") == nil)
    }

    @Test func parsesTrip() throws {
        let status = try Transitous.parse(trip: fixture("transitous_trip"), now: utc("2026-10-05T19:00:00Z"))
        #expect(status.trainName == "ICE 777")
        #expect(status.destination == "Frankfurt (Main) Hbf")
        #expect(status.speed == nil)
        #expect(status.stops.count == 8)
        #expect(status.stops.first?.delayMinutes == 10)
        #expect(status.stops.first?.track == "3")
        let next = try #require(status.nextStop)
        #expect(status.stops.prefix { $0.passed }.count == status.stops.firstIndex(of: next))
        #expect(status.progress.map { $0 > 0 && $0 < 1 } == true)
    }

    @Test func parsesDepartureBoard() throws {
        let departures = try TransitousClient.parseDepartures(fixture("transitous_stoptimes"))
        #expect(!departures.isEmpty)
        // DELFI and VBN both list Hannover-region trains; each should appear once.
        let keys = departures.map { "\($0.line)|\($0.scheduled?.timeIntervalSince1970 ?? 0)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func filtersByLineOrNumber() {
        func departure(_ name: String) -> TransitousClient.Departure {
            .init(tripID: name, displayName: name, line: TransitousClient.lineName(from: name), headsign: nil,
                  scheduled: nil, expected: nil, track: nil, cancelled: false, realTime: true)
        }
        let board = [departure("RE70 (4589)"), departure("RE7 (1234)"), departure("S7"), departure("S70")]
        #expect(TransitousClient.filter(board, line: "re 70").map(\.displayName) == ["RE70 (4589)"])
        #expect(TransitousClient.filter(board, line: "S7").map(\.displayName) == ["S7"])
        #expect(TransitousClient.filter(board, line: "4589").map(\.displayName) == ["RE70 (4589)"])
        #expect(TransitousClient.filter(board, line: "").count == 4)
    }

    @Test func linesForChips() {
        func departure(_ line: String, regional: Bool = true) -> TransitousClient.Departure {
            .init(tripID: line, displayName: line, line: line, headsign: nil, scheduled: nil, expected: nil,
                  track: nil, cancelled: false, realTime: true, isRegional: regional)
        }
        let board = ["RE70", "S11", "ICE 649", "S4", "RB38", "S4", "RE2"].map { departure($0, regional: !$0.hasPrefix("ICE")) }
        #expect(TransitousClient.lines(in: board) == ["S4", "S11", "RB38", "RE2", "RE70"])
    }
}

struct MenuTitleTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func countdown() {
        #expect(MenuTitle.countdown(to: now.addingTimeInterval(402), from: now) == "6:42")
        #expect(MenuTitle.countdown(to: now.addingTimeInterval(3900), from: now) == "1h 05m")
        #expect(MenuTitle.countdown(to: now.addingTimeInterval(-5), from: now, nowLabel: "jetzt") == "jetzt")
    }

    @Test func title() {
        let stop = Stop(id: "a", name: "Augsburg Hbf", expectedArrival: now.addingTimeInterval(402))
        let status = TrainStatus(provider: "DB", stops: [stop], nextStopID: "a")
        let title = MenuTitle.make(status: status, displaySpeed: 248, isTopSpeed: true, now: now, options: .init())
        #expect(title == "🔥 248 km/h · → Augsburg Hbf 6:42")
    }

    @Test func compactMenuBar() {
        let stop = Stop(id: "a", name: "Frankfurt (Main) Flughafen Fernbahnhof", expectedArrival: now.addingTimeInterval(402))
        let status = TrainStatus(provider: "DB", stops: [stop], nextStopID: "a")
        let compact = MenuTitleOptions(stationStyle: .compact, showUnit: false, minutesOnly: true)
        #expect(MenuTitle.make(status: status, displaySpeed: 248, isTopSpeed: false, now: now, options: compact) == "248 · → Frankfurt Flugh. 7′")
        #expect(MenuTitle.shorten("Mönchengladbach Hbf", style: .short) == "Mönchenglad…")
        #expect(MenuTitle.shorten("Ulm Hbf", style: .short) == "Ulm Hbf")
    }

    @Test func standingAtStation() {
        let stop = Stop(id: "a", name: "Frankfurt", expectedArrival: now.addingTimeInterval(-60), expectedDeparture: now.addingTimeInterval(60))
        let status = TrainStatus(provider: "DB", stops: [stop], nextStopID: "a")
        let title = MenuTitle.make(status: status, displaySpeed: 0, isTopSpeed: false, now: now, options: .init())
        #expect(title == "0 km/h · ● Frankfurt")
    }
}

struct StationNameTests {
    @Test(arguments: [
        ("Frankfurt (Main) Hauptbahnhof", "Frankfurt (Main) Hbf"),
        ("Braunschweig, Hauptbahnhof", "Braunschweig Hbf"),
        ("Hannover Hauptbahnhof/ZOB", "Hannover Hbf/ZOB"),
        ("Mörfelden-Walldorf-Walldorf Bahnhof", "Mörfelden-Walldorf-Walldorf"),
        ("Groß-Rohrheim, Bahnhof", "Groß-Rohrheim"),
        ("Haste/Bahnhof", "Haste"),
        ("Gifhorn, Bahnhof (Süd)", "Gifhorn (Süd)"),
        ("Hannover Bahnhof Linden/Fischerhof", "Hannover Linden/Fischerhof"),
        ("Flughafen Köln/Bonn Bf", "Flughafen Köln/Bonn"),
        ("Frankfurt (Main) Flughafen Fernbahnhof", "Frankfurt (Main) Flughafen Fernbahnhof"),
        ("Bahnhof, Erftstadt", "Bahnhof, Erftstadt"),
        ("München Hbf", "München Hbf"),
        ("Bahnhof", "Bahnhof"),
    ])
    func tidy(raw: String, expected: String) {
        #expect(StationName.tidy(raw) == expected)
    }
}

struct LinkTests {
    func links(_ name: String, provider: String = "Transitous") -> [String] {
        TrainStatus(provider: provider, trainName: name).links.map(\.url.absoluteString)
    }

    @Test func longDistance() {
        let urls = links("ICE 503")
        #expect(urls.count == 2)
        #expect(urls[0] == "https://bahn.expert/details/ICE%20503")
        #expect(urls[1] == "https://www.zugfinder.net/de/zug-ICE_503")
    }

    @Test func regionalUsesTrainNumber() {
        #expect(links("RE70 (4589)").first == "https://bahn.expert/details/RE%204589")
        #expect(links("S3").isEmpty)
    }

    @Test func portalComesFirstOnBoard() throws {
        let status = try ICEPortal.parse(status: DemoProvider.resource("demo_db_status"), trip: DemoProvider.resource("demo_db_trip"))
        #expect(status.links.first == TrainLink(kind: .portal("ICE Portal"), url: URL(string: "https://iceportal.de")!))
        #expect(status.links.count == 3)
    }
}

struct CityNameTests {
    @Test func detectsNamesWithoutCity() {
        #expect(StationName.lacksCity("Hauptbahnhof (oben)"))
        #expect(StationName.lacksCity("Hbf"))
        #expect(!StationName.lacksCity("Stuttgart Hbf"))
        #expect(!StationName.lacksCity("Bahnhofstraße"))
    }

    @Test func replacesWithNearbyStationName() async throws {
        let trip = Data(#"{"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 619","from":{"name":"Mannheim Hbf","lat":49.47,"lon":8.46,"departure":"2026-10-06T10:00:00Z"},"to":{"name":"Hauptbahnhof (oben)","lat":48.784,"lon":9.1817,"arrival":"2026-10-06T11:00:00Z"}}]}"#.utf8)
        let geocode = Data(#"[{"name":"Stuttgart Hauptbahnhof"},{"name":"Staatsgalerie"}]"#.utf8)
        let loader: DataLoader = { url in url.path.contains("reverse-geocode") ? geocode : trip }
        let status = try await Transitous(tripID: "x", label: "ICE 619", loader: loader).fetch()
        #expect(status.stops.last?.name == "Stuttgart Hbf")
    }
}
