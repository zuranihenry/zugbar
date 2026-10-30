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
