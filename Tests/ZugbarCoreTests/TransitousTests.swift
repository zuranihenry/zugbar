import Foundation
import Testing
@testable import ZugbarCore

struct TransitousTests {
    @Test func matchesTrainNames() throws {
        let data = try fixture("transitous_map_trips")
        let id = "20260615_18:16_de-DELFI_3426062749"
        #expect(try Transitous.matchTrip(in: data, query: "ICE 1777")?.tripID == id)
        #expect(try Transitous.matchTrip(in: data, query: "ice1777")?.tripID == id)
        #expect(try Transitous.matchTrip(in: data, query: "1777") == .init(tripID: id, ambiguous: false))
        #expect(try Transitous.matchTrip(in: data, query: "ICE 123") == nil)
        #expect(try Transitous.matchTrip(in: data, query: "CAG-POZ") == nil)
    }

    /// "1356" is both a Swedish train and ICE 1356; the ICE should win even when only the Swedish one is moving yet.
    @Test func prefersLongDistanceForBareNumbers() async throws {
        let swedish = #"[{"mode":"LONG_DISTANCE","trips":[{"tripId":"se-1072","displayName":"1356"}]}]"#
        let german = #"[{"mode":"HIGHSPEED_RAIL","trips":[{"tripId":"de-1072","displayName":"ICE 1356"}]}]"#
        let loader: DataLoader = { url in
            let isCoreArea = url.query?.contains("min=45.5") == true
            return Data((isCoreArea ? german : swedish).utf8)
        }
        let now = Date()
        #expect(try await Transitous(query: "1356", loader: loader).findTrip(named: "1356", now: now) == "de-1072")
        #expect(try await Transitous(query: "1356", loader: { _ in Data(swedish.utf8) }).findTrip(named: "1356", now: now) == "se-1072")
        #expect(try Transitous.matchTrip(in: Data(swedish.utf8), query: "1356")?.ambiguous == true)
        #expect(try Transitous.matchTrip(in: Data(swedish.utf8), query: "ICE 1356") == nil)
    }

    @Test func parsesTrip() throws {
        let status = try Transitous.parse(trip: fixture("transitous_trip"), now: utc("2026-06-15T19:00:00Z"))
        #expect(status.trainName == "ICE 1777")
        #expect(status.destination == "Oberwald (Main) Hbf")
        #expect(status.speed == nil)
        #expect(status.stops.count == 8)
        #expect(status.stops.first?.delayMinutes == 10)
        #expect(status.stops.first?.track == "3")
        let next = try #require(status.nextStop)
        #expect(status.stops.prefix { $0.passed }.count == status.stops.firstIndex(of: next))
        #expect(status.progress.map { $0 > 0 && $0 < 1 } == true)
    }

    @Test func keepsScheduledTrack() throws {
        let trip = Data(#"""
        {"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 1",
          "from":{"name":"Ahornstadt Hbf","track":"3","scheduledTrack":"3"},
          "intermediateStops":[{"name":"Buchenweiler","track":"8","scheduledTrack":"6"}],
          "to":{"name":"Eibental","track":"1"}}]}
        """#.utf8)
        let stops = try Transitous.parse(trip: trip, now: utc("2099-01-01T00:00:00Z")).stops
        #expect(stops.map(\.track) == ["3", "8", "1"])
        #expect(stops.map(\.scheduledTrack) == ["3", "6", nil])
        #expect(stops.map(\.trackChanged) == [false, true, false])
    }

    @Test func parsesDepartureBoard() throws {
        let departures = try TransitousClient.parseDepartures(fixture("transitous_stoptimes"))
        #expect(!departures.isEmpty)
        // DELFI and RBN both list Weidenhagen-region trains; each should appear once.
        let keys = departures.map { "\($0.line)|\($0.scheduled?.timeIntervalSince1970 ?? 0)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func filtersByLineOrNumber() {
        func departure(_ name: String) -> TransitousClient.Departure {
            .init(tripID: name, displayName: name, line: TransitousClient.lineName(from: name), headsign: nil,
                  scheduled: nil, expected: nil, track: nil, cancelled: false, realTime: true)
        }
        let board = [departure("RE80 (4711)"), departure("RE8 (1234)"), departure("S8"), departure("S80")]
        #expect(TransitousClient.filter(board, line: "re 80").map(\.displayName) == ["RE80 (4711)"])
        #expect(TransitousClient.filter(board, line: "S8").map(\.displayName) == ["S8"])
        #expect(TransitousClient.filter(board, line: "4711").map(\.displayName) == ["RE80 (4711)"])
        #expect(TransitousClient.filter(board, line: "").count == 4)
    }

    @Test func linesForChips() {
        func departure(_ line: String, regional: Bool = true) -> TransitousClient.Departure {
            .init(tripID: line, displayName: line, line: line, headsign: nil, scheduled: nil, expected: nil,
                  track: nil, cancelled: false, realTime: true, isRegional: regional)
        }
        let board = ["RE80", "S11", "ICE 649", "S4", "RB38", "S4", "RE2"].map { departure($0, regional: !$0.hasPrefix("ICE")) }
        #expect(TransitousClient.lines(in: board) == ["S4", "S11", "RB38", "RE2", "RE80"])
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
        let stop = Stop(id: "a", name: "Oberwald (Main) Flughafen Fernbahnhof", expectedArrival: now.addingTimeInterval(402))
        let status = TrainStatus(provider: "DB", stops: [stop], nextStopID: "a")
        let compact = MenuTitleOptions(stationStyle: .compact, showUnit: false, minutesOnly: true)
        #expect(MenuTitle.make(status: status, displaySpeed: 248, isTopSpeed: false, now: now, options: compact) == "248 · → Oberwald Flugh. 7′")
        #expect(MenuTitle.shorten("Mönchengladbach Hbf", style: .short) == "Mönchenglad…")
        #expect(MenuTitle.shorten("Ulm Hbf", style: .short) == "Ulm Hbf")
        // The ICE portal writes some names without spaces around the parentheses.
        #expect(MenuTitle.shorten("Oberwald(Main)Hbf", style: .compact) == "Oberwald Hbf")
        #expect(MenuTitle.shorten("Freiburg(Breisgau) Hbf", style: .compact) == "Freiburg Hbf")
        #expect(MenuTitle.shorten("Berlin Hauptbahnhof", style: .compact) == "Berlin Hbf")
    }

    @Test func automaticStationNamesShortenOnlyWhenTooWide() {
        let stop = Stop(id: "a", name: "Oberwald (Main) Flughafen Fernbahnhof", expectedArrival: now.addingTimeInterval(402))
        let status = TrainStatus(provider: "DB", stops: [stop], nextStopID: "a")
        // One point per character stands in for the menu bar's font.
        func fitted(_ style: MenuTitleOptions.StationStyle, maxWidth: Double) -> String {
            MenuTitle.fitted(MenuTitleOptions(stationStyle: style), maxWidth: maxWidth, width: { Double($0.count) }) {
                MenuTitle.make(status: status, displaySpeed: 248, isTopSpeed: false, now: now, options: $0)
            }
        }
        #expect(fitted(.automatic, maxWidth: 100) == "248 km/h · → Oberwald (Main) Flughafen Fernbahnhof 6:42")
        #expect(fitted(.automatic, maxWidth: 40) == "248 km/h · → Oberwald Flugh. 6:42")
        #expect(fitted(.automatic, maxWidth: 20) == "248 km/h · → Oberwald Fl… 6:42")
        // A chosen style stays as chosen.
        #expect(fitted(.full, maxWidth: 20) == "248 km/h · → Oberwald (Main) Flughafen Fernbahnhof 6:42")
        #expect(MenuTitle.shorten("Oberwald (Main)", style: .automatic) == "Oberwald (Main)")
    }

    @Test func standingAtStation() {
        let stop = Stop(id: "a", name: "Oberwald", expectedArrival: now.addingTimeInterval(-60), expectedDeparture: now.addingTimeInterval(60))
        let status = TrainStatus(provider: "DB", stops: [stop], nextStopID: "a")
        let title = MenuTitle.make(status: status, displaySpeed: 0, isTopSpeed: false, now: now, options: .init())
        #expect(title == "0 km/h · ● Oberwald")
    }
}

struct StationNameTests {
    @Test(arguments: [
        ("Oberwald (Main) Hauptbahnhof", "Oberwald (Main) Hbf"),
        ("Eschenbrück, Hauptbahnhof", "Eschenbrück Hbf"),
        ("Weidenhagen Hauptbahnhof/ZOB", "Weidenhagen Hbf/ZOB"),
        ("Haselwald-Weidenwald-Weidenwald Bahnhof", "Haselwald-Weidenwald-Weidenwald"),
        ("Groß-Sandheim, Bahnhof", "Groß-Sandheim"),
        ("Zedernhausen/Bahnhof", "Zedernhausen"),
        ("Quellbach, Bahnhof (Süd)", "Quellbach (Süd)"),
        ("Weidenhagen Bahnhof Eschenheim/Nesseltal", "Weidenhagen Eschenheim/Nesseltal"),
        ("Flughafen Gerstwald/Dornberg Bf", "Flughafen Gerstwald/Dornberg"),
        ("Oberwald (Main) Flughafen Fernbahnhof", "Oberwald (Main) Flughafen Fernbahnhof"),
        ("Bahnhof, Mohnstedt", "Bahnhof, Mohnstedt"),
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
        #expect(links("RE80 (4711)").first == "https://bahn.expert/details/RE%204711")
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
        let trip = Data(#"{"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 619","from":{"name":"Fahrstedt Hbf","lat":49.47,"lon":8.46,"departure":"2099-10-06T10:00:00Z"},"to":{"name":"Hauptbahnhof (oben)","lat":48.784,"lon":9.1817,"arrival":"2099-10-06T11:00:00Z"}}]}"#.utf8)
        let geocode = Data(#"[{"name":"Stuttgart Hauptbahnhof"},{"name":"Staatsgalerie"}]"#.utf8)
        let loader: DataLoader = { url in url.path.contains("reverse-geocode") ? geocode : trip }
        let status = try await Transitous(tripID: "x", label: "ICE 619", loader: loader).fetch()
        #expect(status.stops.last?.name == "Stuttgart Hbf")
    }

    /// The shape is nearly all of a trip's data: fetched once, then left out of each update.
    @Test func fetchesTheShapeOnce() async throws {
        let stops = #""from":{"name":"Aheim","lat":50.0,"lon":9.0,"departure":"2099-10-06T10:00:00Z"},"to":{"name":"Beheim","lat":50.1,"lon":9.1,"arrival":"2099-10-06T11:00:00Z"}"#
        let full = Data(#"{"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 9",\#(stops),"legGeometry":{"points":"_ibE_mjB_ibE_mjB","precision":5}}]}"#.utf8)
        let light = Data(#"{"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 9",\#(stops),"legGeometry":{"points":"","precision":6}}]}"#.utf8)
        let asked = Asked()
        let loader: DataLoader = { url in
            let shape = url.query?.contains("detailedLegs=false") != true
            await asked.append(shape)
            return shape ? full : light
        }
        let provider = Transitous(tripID: "shape-once", label: "ICE 9", loader: loader)
        let first = try await provider.fetch()
        let second = try await provider.fetch()
        // A new lookup after a network change doesn't need it again either.
        let third = try await Transitous(tripID: "shape-once", label: "ICE 9", loader: loader).fetch()
        #expect(await asked.shapes == [true, false, false])
        #expect(first.route != nil)
        #expect(second.route == first.route)
        #expect(third.route == first.route)
    }

    @Test func connectionsRefreshWithoutTheShape() {
        #expect(Transitous.tripURL("t", shape: false).query?.contains("detailedLegs=false") == true)
        #expect(Transitous.tripURL("t", shape: true).query?.contains("detailedLegs") == false)
    }
}

private actor Asked {
    var shapes: [Bool] = []
    func append(_ shape: Bool) { shapes.append(shape) }
}
