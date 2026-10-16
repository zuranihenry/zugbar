import Foundation
import Testing
@testable import ZugbarCore

struct SBBTests {
    let now = utc("2026-03-02T12:00:00Z")

    func departure(_ name: String, minutesAgo: Double, switzerland: Bool = false, regional: Bool = false,
                   cancelled: Bool = false) -> TransitousClient.Departure {
        TransitousClient.Departure(
            tripID: name, displayName: name, line: name, headsign: nil,
            scheduled: now.addingTimeInterval(-minutesAgo * 60 - 600), expected: now.addingTimeInterval(-minutesAgo * 60),
            track: nil, cancelled: cancelled, realTime: true, isRegional: regional, servesSwitzerland: switzerland
        )
    }

    @Test func trainWiFi() {
        #expect(SBB.isTrainWiFi(domain: "guest.freewlan.sbb.ch"))
        #expect(SBB.isTrainWiFi(domain: "guest.freewlan.sbb.ch\0"))
        #expect(SBB.isTrainWiFi(domain: "FreeWLAN.SBB.ch"))
        #expect(!SBB.isTrainWiFi(domain: "fritz.box"))
        #expect(!SBB.isTrainWiFi(domain: "notfreewlan.sbb.ch"))
        #expect(!SBB.isTrainWiFi(domain: nil))
    }

    @Test func candidates() {
        let departures = [
            departure("ECE 90", minutesAgo: 40),
            departure("ICE 800", minutesAgo: 5, switzerland: true),
            departure("EC 70", minutesAgo: 10, switzerland: true),
            departure("IC 60", minutesAgo: 3),
            departure("ECE 91", minutesAgo: 90),
            departure("ECE 92", minutesAgo: -10),
            departure("ECE 94", minutesAgo: -20),
            departure("ECE 93", minutesAgo: 2, cancelled: true),
        ]
        // Joined the Wi-Fi 12 minutes ago: the train leaving around then first; one leaving soon still counts.
        let joined = now.addingTimeInterval(-12 * 60)
        #expect(SBB.candidates(departures, now: now, joined: joined).map(\.displayName) == ["EC 70", "ECE 92", "ECE 90"])
    }

    @Test func stopID() {
        #expect(SBB.transitousStopID("2-de-DELFI_de:00001:10:15:3") == "de-DELFI_de:00001:10:15:3")
        #expect(SBB.transitousStopID("12-ch:1:sloid:7") == "ch:1:sloid:7")
        #expect(SBB.transitousStopID("8000001_00") == nil)
        #expect(SBB.transitousStopID("3-Altstadt") == nil)
        #expect(SBB.transitousStopID(nil) == nil)
    }

    @Test func movesThePlan() {
        let trip = TrainStatus(provider: "Transitous", trainName: "ECE 90", stops: [
            Stop(id: "0-a", name: "Altstadt Hbf", passed: true),
            Stop(id: "1-b", name: "Brückenfeld Hauptbahnhof"),
            Stop(id: "2-c", name: "Coswig Süd", cancelled: true),
            Stop(id: "3-d", name: "Dornstadt"),
        ])
        #expect(SBB.serves(trip, from: "Brückenfeld Hbf", to: "Dornstadt"))
        #expect(!SBB.serves(trip, from: "Brückenfeld Hbf", to: "Coswig Süd"))
        #expect(!SBB.serves(trip, from: "Dornstadt", to: "Brückenfeld Hbf"))
        #expect(!SBB.serves(trip, from: "Endhausen", to: "Dornstadt"))

        let connection = Connection(tripID: "x", name: "RE 5", headsign: nil, station: "Dornstadt",
                                    scheduledDeparture: nil, expectedDeparture: nil, track: nil)
        let old = JourneyPlan(trainName: "ICE 800", boardingStopID: "1-q", destinationStopID: "4-r", connection: connection)
        let moved = SBB.plan(old, on: "ECE 90", from: "Brückenfeld Hbf", to: "Dornstadt").resolved(in: trip)
        #expect(moved.trainName == "ECE 90")
        #expect(moved.boardingStopID == "1-b")
        #expect(moved.destinationStopID == "3-d")
        #expect(moved.connection == connection)
    }
}
