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
