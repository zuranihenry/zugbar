import Foundation
import Testing
@testable import ZugbarCore

struct PlatformChangeTests {
    let now = utc("2099-01-01T10:10:00Z")

    /// The destination's platform, as Transitous gives it: each platform has its own stop ID.
    func trip(stopId: String, parentId: String?, track: String) -> Data {
        let parent = parentId.map { #","parentId":"\#($0)""# } ?? ""
        return Data(#"""
        {"legs":[{"mode":"REGIONAL_RAIL","displayName":"RE 7",
          "from":{"name":"Ahornstadt","stopId":"de:1:1:1","departure":"2099-01-01T10:00:00Z"},
          "to":{"name":"Buchenweiler Hbf","stopId":"\#(stopId)"\#(parent),"track":"\#(track)","scheduledTrack":"10",
                "arrival":"2099-01-01T10:30:00Z","scheduledArrival":"2099-01-01T10:30:00Z"}}]}
        """#.utf8)
    }

    @Test(arguments: ["de:2:5", nil] as [String?])
    func trackChangeAtTheDestinationIsNoticed(parentId: String?) throws {
        let old = try Transitous.parse(trip: trip(stopId: "de:2:5:94:7", parentId: parentId, track: "10"), now: now)
        let new = try Transitous.parse(trip: trip(stopId: "de:2:5:92:6", parentId: parentId, track: "9"), now: now)
        // With a station ID the stop keeps its ID; without one it changes, and is still found by its place in the trip.
        #expect((old.stops[1].id == new.stops[1].id) == (parentId != nil))
        let plan = JourneyPlan(trainName: "RE 7", destinationStopID: new.stops[1].id)
        let events = JourneyWatcher.events(old: old, oldTime: now, oldConnection: nil,
                                           new: new, newTime: now.addingTimeInterval(60), newConnection: nil, plan: plan)
        #expect(events.contains(.trackChanged(stop: "Buchenweiler Hbf", from: "10", to: "9")))
    }

    /// Another source's stops aren't compared with the new ones, even when one has the same name.
    @Test func otherSourceIsNotCompared() {
        let stop = { (id: String, track: String) in
            Stop(id: id, name: "Buchenweiler Hbf", scheduledArrival: now.addingTimeInterval(1200), track: track)
        }
        let portal = TrainStatus(provider: "DB", trainName: "ICE 7", stops: [stop("8000001", "4")])
        let online = TrainStatus(provider: "Transitous", trainName: "ICE 7", stops: [stop("0-de:2:5", "5")])
        let plan = JourneyPlan(trainName: "ICE 7", destinationStopID: "0-de:2:5")
        #expect(JourneyWatcher.events(old: portal, oldTime: now, oldConnection: nil,
                                      new: online, newTime: now.addingTimeInterval(60), newConnection: nil, plan: plan).isEmpty)
    }
}

struct DepartureBoardTests {
    func departure(_ tripID: String, realTime: Bool = true) -> TransitousClient.Departure {
        .init(tripID: tripID, displayName: "RB 12", line: "RB 12", headsign: nil, scheduled: utc("2099-01-01T10:00:00Z"),
              expected: nil, track: nil, cancelled: false, realTime: realTime)
    }

    /// Trains of one line crossing at a station leave the same minute in opposite directions; both stay.
    @Test func keepsBothDirections() {
        let board = [departure("20990101_09:20_de-DELFI_1"), departure("20990101_09:45_de-DELFI_2")]
        #expect(TransitousClient.deduplicated(board).map(\.tripID) == ["20990101_09:20_de-DELFI_1", "20990101_09:45_de-DELFI_2"])
    }

    @Test func dropsTheSameTrainFromAnotherFeed() {
        let board = [departure("20990101_09:20_de-DELFI_1", realTime: false), departure("20990101_09:20_de-RBN_7")]
        #expect(TransitousClient.deduplicated(board).map(\.tripID) == ["20990101_09:20_de-RBN_7"])
    }
}

struct CutShortTests {
    func trip(tripCancelled: Bool) -> Data {
        Data(#"""
        {"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 7","headsign":"Eibental Hbf","cancelled":\#(tripCancelled),
          "from":{"name":"Ahornstadt","departure":"2099-01-01T10:00:00Z"},
          "intermediateStops":[{"name":"Buchenweiler","arrival":"2099-01-01T10:30:00Z"},
                               {"name":"Dornstadt","arrival":"2099-01-01T10:50:00Z","cancelled":true}],
          "to":{"name":"Eibental Hauptbahnhof","arrival":"2099-01-01T11:10:00Z","cancelled":true}}]}
        """#.utf8)
    }

    @Test func endsAtTheLastStopServed() throws {
        let status = try Transitous.parse(trip: trip(tripCancelled: false), now: utc("2099-01-01T10:10:00Z"))
        #expect(status.destination == "Buchenweiler")
    }

    @Test func aCancelledTripKeepsItsDestination() throws {
        let status = try Transitous.parse(trip: trip(tripCancelled: true), now: utc("2099-01-01T10:10:00Z"))
        #expect(status.destination == "Eibental Hbf")
    }
}

struct CityNameRetryTests {
    let trip = Data(#"{"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 7","from":{"name":"Fahrstedt Hbf","lat":49.1,"lon":8.1,"departure":"2099-10-06T10:00:00Z"},"to":{"name":"Hauptbahnhof (oben)","lat":48.2,"lon":9.2,"arrival":"2099-10-06T11:00:00Z"}}]}"#.utf8)

    /// In a tunnel the lookup fails; the next update asks again.
    @Test func asksAgainAfterANetworkError() async throws {
        let lookups = Counter()
        let trip = trip
        let loader: DataLoader = { url in
            guard url.path.contains("reverse-geocode") else { return trip }
            await lookups.increment()
            if await lookups.value == 1 { throw URLError(.timedOut) }
            return Data(#"[{"name":"Ahornstadt Hauptbahnhof"}]"#.utf8)
        }
        let transitous = Transitous(tripID: "x", label: "ICE 7", loader: loader)
        #expect(try await transitous.fetch().stops.last?.name == "Hauptbahnhof (oben)")
        #expect(try await transitous.fetch().stops.last?.name == "Ahornstadt Hbf")
        _ = try await transitous.fetch()
        #expect(await lookups.value == 2)
    }

    /// An answer that can't be used isn't asked for again on every update.
    @Test func keepsAnUnusableAnswer() async throws {
        let lookups = Counter()
        let trip = trip
        let loader: DataLoader = { url in
            guard url.path.contains("reverse-geocode") else { return trip }
            await lookups.increment()
            return Data("not json".utf8)
        }
        let transitous = Transitous(tripID: "x", label: "ICE 7", loader: loader)
        _ = try await transitous.fetch()
        #expect(try await transitous.fetch().stops.last?.name == "Hauptbahnhof (oben)")
        #expect(await lookups.value == 1)
    }
}

struct RenumberedTripTests {
    func map(_ tripID: String, _ name: String) -> Data {
        Data(#"[{"mode":"HIGHSPEED_RAIL","trips":[{"tripId":"\#(tripID)","displayName":"\#(name)"}]}]"#.utf8)
    }

    let trip = Data(#"""
    {"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 9701",
      "from":{"name":"Ahornstadt","departure":"2099-01-01T10:00:00Z"},"to":{"name":"Buchenweiler","arrival":"2099-01-01T11:00:00Z"}}]}
    """#.utf8)

    /// Transitous reloaded a feed and the trip got a new ID: one more search finds it.
    @Test func searchesAgainAfterA404() async throws {
        let reloaded = Counter()
        let (old, new, trip) = (map("old", "ICE 9701"), map("new", "ICE 9701"), trip)
        let loader: DataLoader = { url in
            let isReloaded = await reloaded.value > 0
            if url.path.hasSuffix("map/trips") { return isReloaded ? new : old }
            if url.query?.contains("tripId=old") == true, isReloaded { throw ProviderError.badStatus(404) }
            return trip
        }
        let transitous = Transitous(query: "ICE 9701", loader: loader)
        #expect(try await transitous.fetch().trainName == "ICE 9701")
        await reloaded.increment()
        #expect(try await transitous.fetch().trainName == "ICE 9701")
    }

    /// A trip that keeps answering 404 waits like a train that isn't running, without a map download per update.
    @Test func aDeadTripIsNotSearchedOnEveryUpdate() async throws {
        let searches = Counter()
        let map = map("dead", "ICE 9702")
        let loader: DataLoader = { url in
            if url.path.hasSuffix("map/trips") {
                await searches.increment()
                return map
            }
            throw ProviderError.badStatus(404)
        }
        let transitous = Transitous(query: "ICE 9702", loader: loader)
        await #expect(throws: ProviderError.badStatus(404)) { try await transitous.fetch() }
        await #expect(throws: Transitous.LookupError.notRunning) { try await transitous.fetch() }
        await #expect(throws: Transitous.LookupError.notRunning) { try await transitous.fetch() }
        #expect(await searches.value == 2)
    }
}

struct ConnectionRefreshTests {
    let trip = Data(#"""
    {"legs":[{"mode":"REGIONAL_RAIL","displayName":"RE 3",
      "from":{"name":"Hauptbahnhof (oben)","scheduledDeparture":"2099-01-01T10:00:00Z","departure":"2099-01-01T10:06:00Z","track":"12"},
      "to":{"name":"Buchenweiler","scheduledArrival":"2099-01-01T11:00:00Z"}}]}
    """#.utf8)

    func connection(at station: String, departure: String = "2099-01-01T10:00:00Z") -> Connection {
        Connection(tripID: "re3", name: "RE 3", headsign: "Buchenweiler", station: station,
                   scheduledDeparture: utc(departure), expectedDeparture: nil, track: "11")
    }

    /// The followed train calls the station "Ahornstadt Hbf"; the connection's trip has only "Hauptbahnhof (oben)".
    @Test func findsTheStopByItsDeparture() async throws {
        let trip = trip
        let updated = try await TransitousClient(loader: { _ in trip }).refresh(connection(at: "Ahornstadt Hbf"))
        #expect(updated.delayMinutes == 6)
        #expect(updated.track == "12")
    }

    /// An S-Bahn's stops can be a minute apart; the one planned for the connection is taken, not the one before.
    @Test func takesTheClosestDeparture() async throws {
        let trip = Data(#"""
        {"legs":[{"mode":"SUBURBAN","displayName":"S 4",
          "from":{"name":"Bahnhof (Nord)","scheduledDeparture":"2099-01-01T09:59:00Z","track":"1"},
          "intermediateStops":[{"name":"Hauptbahnhof (tief)","scheduledDeparture":"2099-01-01T10:00:00Z",
                                "departure":"2099-01-01T10:04:00Z","track":"2"}],
          "to":{"name":"Buchenweiler","scheduledArrival":"2099-01-01T10:20:00Z"}}]}
        """#.utf8)
        let updated = try await TransitousClient(loader: { _ in trip }).refresh(connection(at: "Ahornstadt Hbf"))
        #expect(updated.track == "2")
        #expect(updated.delayMinutes == 4)
    }

    @Test func matchesNamesSpelledDifferently() async throws {
        let trip = Data(#"{"legs":[{"mode":"REGIONAL_RAIL","from":{"name":"Ahornstadt Hbf","departure":"2099-01-01T10:20:00Z"},"to":{"name":"Buchenweiler"}}]}"#.utf8)
        let updated = try await TransitousClient(loader: { _ in trip })
            .refresh(connection(at: "Ahornstadt Hauptbahnhof", departure: "2099-01-01T10:05:00Z"))
        #expect(updated.expectedDeparture == utc("2099-01-01T10:20:00Z"))
    }

    @Test func leavesAnUnknownStopAlone() async throws {
        let trip = trip
        let original = connection(at: "Dornstadt", departure: "2099-01-01T09:00:00Z")
        #expect(try await TransitousClient(loader: { _ in trip }).refresh(original) == original)
    }
}

struct OEBBNumberTests {
    @Test func numbersEitherWay() throws {
        let json = Data(#"""
        {"trainType":"RJ","tripNumber":"7","latestStatus":{"speed":"143","gpsPosition":{"latitude":47.5,"longitude":13.1}},
         "stations":[{"id":"1","name":{"all":"Ahornstadt"}},{"id":"2","name":{"all":"Buchenweiler"}}]}
        """#.utf8)
        let status = try OEBBRailnet.parse(combined: json, now: utc("2099-01-01T10:00:00Z"))
        #expect(status.speed == 143)
        #expect(status.position == Coordinate(latitude: 47.5, longitude: 13.1))
    }

    @Test func oddValuesDropOnlyThemselves() throws {
        let json = Data(#"""
        {"latestStatus":{"speed":true,"gpsPosition":{"latitude":"","longitude":{}}},
         "stations":[{"id":"1","name":{"all":"Ahornstadt"}}]}
        """#.utf8)
        let status = try OEBBRailnet.parse(combined: json, now: utc("2099-01-01T10:00:00Z"))
        #expect(status.speed == nil)
        #expect(status.position == nil)
        #expect(status.stops.count == 1)
    }
}
