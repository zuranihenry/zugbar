import Foundation
import Testing
@testable import ZugbarCore

struct HandoverTests {
    let now = utc("2026-06-12T16:00:00Z")

    func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

    var connection: Connection {
        Connection(
            tripID: "20260612_RE1", name: "RE 1", headsign: "Regensburg Hbf", station: "Nürnberg Hbf",
            scheduledDeparture: minutes(10), expectedDeparture: nil, track: "12",
            finalStop: "Regensburg Hbf", finalArrival: minutes(70)
        )
    }

    func ice(name: String = "ICE 1072", arrival: Date, passed: Bool = false, cancelled: Bool = false) -> TrainStatus {
        TrainStatus(provider: "DB", trainName: name, stops: [
            Stop(id: "erl", name: "Erlangen", scheduledDeparture: minutes(-20), passed: true),
            Stop(id: "nbg", name: "Nürnberg Hbf", scheduledArrival: arrival, passed: passed, cancelled: cancelled),
            Stop(id: "muc", name: "München Hbf", scheduledArrival: minutes(60)),
        ])
    }

    var plan: JourneyPlan { JourneyPlan(trainName: "ICE 1072", destinationStopID: "nbg", connection: connection) }

    @Test func dueOnceTheTrainArrivesAtTheDestination() {
        #expect(!Handover.isDue(plan: plan, status: ice(arrival: minutes(1)), now: now))
        #expect(Handover.isDue(plan: plan, status: ice(arrival: now), now: now))
        #expect(Handover.isDue(plan: plan, status: ice(arrival: minutes(5), passed: true), now: now))
    }

    @Test func leewayCountsAnArrivalThatIsAboutToHappen() {
        #expect(Handover.isDue(plan: plan, status: ice(arrival: minutes(2)), now: now, leeway: 3 * 60))
        #expect(!Handover.isDue(plan: plan, status: ice(arrival: minutes(10)), now: now, leeway: 3 * 60))
    }

    @Test func notDueWithoutConnectionOrForAnotherTrain() {
        var withoutConnection = plan
        withoutConnection.connection = nil
        #expect(!Handover.isDue(plan: withoutConnection, status: ice(arrival: now), now: now))
        #expect(!Handover.isDue(plan: plan, status: ice(name: "ICE 599", arrival: now), now: now))
        #expect(!Handover.isDue(plan: nil, status: ice(arrival: now), now: now))
        #expect(!Handover.isDue(plan: plan, status: nil, now: now))
    }

    @Test func notDueWhenTheDestinationIsCancelled() {
        #expect(!Handover.isDue(plan: plan, status: ice(arrival: now, cancelled: true), now: now))
    }

    @Test func otherSpellingOfTheTrainStillCounts() {
        #expect(Handover.isDue(plan: plan, status: ice(name: "ICE1072", arrival: now), now: now))
    }

    @Test func connectionThatLeftLongAgoIsNotFollowed() {
        // A plan from yesterday comes back when the same train number runs again.
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        #expect(!Handover.isDue(plan: plan, status: ice(arrival: tomorrow), now: tomorrow))
        #expect(!Handover.isDueAfterTripEnded(plan: plan, trainName: "ICE 1072", now: tomorrow))
    }

    @Test func dueAfterTheFollowedTripEnded() {
        #expect(Handover.isDueAfterTripEnded(plan: plan, trainName: "ICE 1072", now: now))
        #expect(Handover.isDueAfterTripEnded(plan: plan, trainName: "ICE 1072 → München Hbf", now: now))
        #expect(!Handover.isDueAfterTripEnded(plan: plan, trainName: "RE 1", now: now))
        #expect(!Handover.isDueAfterTripEnded(plan: plan, trainName: nil, now: now))
    }

    @Test func followsTransitousConnectionsByTrip() {
        #expect(Handover.target(for: connection) == .trip(id: "20260612_RE1", label: "RE 1 → Regensburg Hbf"))
    }

    @Test func followsPortalConnectionsByName() {
        var portal = connection
        portal.tripID = "iceportal:8000284:ICE 1001"
        portal.name = "ICE 1001"
        portal.portalStationID = "8000284_00"
        #expect(Handover.target(for: portal) == .name("ICE 1001"))
    }

    @Test func newPlanCarriesOverTheConnectionsStops() {
        let next = Handover.plan(after: connection)
        #expect(next.trainName == "RE 1")
        #expect(next.connection == nil)
        #expect(next.pendingBoarding == "Nürnberg Hbf")
        #expect(next.pendingDestination == "Regensburg Hbf")
    }

    @Test func pendingStopsResolveAgainstTheNewTrain() {
        let regional = TrainStatus(provider: "Transitous", trainName: "RE 1", stops: [
            Stop(id: "0-fue", name: "Fürth Hbf"),
            Stop(id: "1-nbg", name: "Nürnberg Hauptbahnhof"),
            Stop(id: "2-nm", name: "Neumarkt (Oberpf)"),
            Stop(id: "3-rbg", name: "Regensburg Hbf"),
        ])
        let resolved = Handover.plan(after: connection).resolved(in: regional)
        #expect(resolved.boardingStopID == "1-nbg")
        #expect(resolved.destinationStopID == "3-rbg")
        #expect(resolved.pendingBoarding == nil)
        #expect(resolved.pendingDestination == nil)
    }

    @Test func destinationMustComeAfterBoarding() {
        // A train running the other way passes the final stop first.
        let opposite = TrainStatus(provider: "Transitous", trainName: "RE 1", stops: [
            Stop(id: "0-rbg", name: "Regensburg Hbf"),
            Stop(id: "1-nbg", name: "Nürnberg Hbf"),
        ])
        let resolved = Handover.plan(after: connection).resolved(in: opposite)
        #expect(resolved.boardingStopID == "1-nbg")
        #expect(resolved.destinationStopID == nil)
        #expect(resolved.pendingDestination == "Regensburg Hbf")
    }

    @Test func resolvingTakesOverThePortalsSpelling() {
        var plan = Handover.plan(after: connection)
        plan.trainName = "ICE 1001"
        let portal = TrainStatus(provider: "DB", trainName: "ICE1001", stops: [])
        #expect(plan.resolved(in: portal).trainName == "ICE1001")
    }

    @Test func fallbackLastsUntilAQuarterHourAfterTheLastStop() {
        #expect(Handover.fallbackDeadline(for: ice(arrival: minutes(5)), now: now) == minutes(75))
        let unknown = TrainStatus(provider: "DB", trainName: "ICE 1072", stops: [])
        #expect(Handover.fallbackDeadline(for: unknown, now: now) == minutes(60))
    }

    @Test func planFollowsTheTrainFromItsPortalToTransitous() {
        let portal = TrainStatus(provider: "DB", trainName: "ICE 1072", stops: [
            Stop(id: "8001844_00", name: "Erlangen"),
            Stop(id: "8000284_00", name: "Nürnberg Hbf"),
            Stop(id: "8000261_00", name: "München Hbf"),
        ])
        let online = TrainStatus(provider: "Transitous", trainName: "ICE 1072", stops: [
            Stop(id: "0-erl", name: "Erlangen"),
            Stop(id: "1-nbg", name: "Nürnberg Hauptbahnhof"),
            Stop(id: "2-muc", name: "München Hbf"),
        ])
        let plan = JourneyPlan(trainName: "ICE 1072", boardingStopID: "8001844_00", destinationStopID: "8000284_00")
        let moved = plan.remapped(from: portal, to: online)
        #expect(moved.boardingStopID == "0-erl")
        #expect(moved.destinationStopID == "1-nbg")
        #expect(moved.remapped(from: online, to: portal) == plan)
    }

    @Test func remappingLeavesOtherTrainsAlone() {
        let portal = TrainStatus(provider: "DB", trainName: "ICE 1072", stops: [Stop(id: "8000284_00", name: "Nürnberg Hbf")])
        let other = TrainStatus(provider: "Transitous", trainName: "ICE 599", stops: [Stop(id: "0-nbg", name: "Nürnberg Hbf")])
        let plan = JourneyPlan(trainName: "ICE 1072", destinationStopID: "8000284_00")
        #expect(plan.remapped(from: portal, to: other) == plan)
    }

    func departure(_ name: String, at time: Date, headsign: String = "Regensburg Hbf", trip: String) -> TransitousClient.Departure {
        TransitousClient.Departure(
            tripID: trip, displayName: name, line: TransitousClient.lineName(from: name), headsign: headsign,
            scheduled: time, expected: nil, track: nil, cancelled: false, realTime: false
        )
    }

    var portalConnection: Connection {
        Connection(
            tripID: "iceportal:8000284:RE 6", name: "RE 6", headsign: "Regensburg Hbf", station: "Nürnberg Hbf",
            scheduledDeparture: minutes(10), expectedDeparture: nil, track: "12",
            finalStop: "Regensburg Hbf", portalStationID: "8000284_00"
        )
    }

    @Test func findsPortalConnectionOnTheDepartureBoardByLine() {
        let board = [
            departure("RE6 (89734)", at: minutes(-50), trip: "earlier"),
            departure("RB 61", at: minutes(10), headsign: "Neumarkt", trip: "other"),
            departure("RE6 (89736)", at: minutes(10), trip: "wanted"),
        ]
        #expect(Handover.departure(for: portalConnection, in: board)?.tripID == "wanted")
    }

    @Test func findsPortalConnectionByTrainNumber() {
        var connection = portalConnection
        connection.name = "RE 89736"
        let board = [departure("RE6 (89736)", at: minutes(10), trip: "wanted")]
        #expect(Handover.departure(for: connection, in: board)?.tripID == "wanted")
    }

    @Test func fallsBackToCategoryAndHeadsign() {
        var connection = portalConnection
        connection.name = "RE 4"
        let board = [
            departure("RB 61", at: minutes(10), trip: "regional"),
            departure("RE 40", at: minutes(10), trip: "wanted"),
        ]
        #expect(Handover.departure(for: connection, in: board)?.tripID == "wanted")
    }

    @Test func noMatchAtAnotherTime() {
        let board = [departure("RE6 (89738)", at: minutes(70), trip: "later")]
        #expect(Handover.departure(for: portalConnection, in: board) == nil)
    }

    @Test func plansSavedBeforePendingStopsStillLoad() throws {
        let json = #"{"trainName":"ICE 1072","destinationStopID":"nbg"}"#
        let plan = try JSONDecoder().decode(JourneyPlan.self, from: Data(json.utf8))
        #expect(plan.destinationStopID == "nbg")
        #expect(plan.pendingDestination == nil)
    }
}

struct TrainNameTests {
    @Test(arguments: [
        ("ICE 1072", "ICE 1072"),
        ("ICE 1072", "ICE1072"),
        ("ice 1072", "ICE 1072"),
        ("RE70 (4589)", "RE 4589"),
        ("RE 1 → Nürnberg Hbf", "RE 1"),
        ("IC 2013", "ICE 2013"),
    ])
    func same(_ a: String, _ b: String) {
        #expect(TrainName.same(a, b))
    }

    @Test(arguments: [
        ("ICE 1072", "ICE 599"),
        ("RE 1", "RB 1"),
        ("RE 1", "S 1"),
        ("ICE 1072", "RE 1"),
    ])
    func different(_ a: String, _ b: String) {
        #expect(!TrainName.same(a, b))
    }

    @Test func missedConnection() {
        let departure = utc("2026-06-12T16:20:00Z")
        let connection = Connection(tripID: "re-1", name: "RE 1", headsign: "B", station: "A",
                                    scheduledDeparture: departure, expectedDeparture: departure, track: "1", finalStop: "B")
        #expect(!Handover.isMissed(connection, arrival: departure.addingTimeInterval(-6 * 60)))
        #expect(Handover.isMissed(connection, arrival: departure.addingTimeInterval(4 * 60)))
        #expect(!Handover.isMissed(connection, arrival: nil))
    }

    @Test func replacementIsTheNextTrainThatRuns() {
        let missed = utc("2026-06-12T16:20:00Z")
        func train(_ id: String, minutes: Double, cancelled: Bool = false) -> Connection {
            let time = missed.addingTimeInterval(minutes * 60)
            return Connection(tripID: id, name: "RE 1", headsign: nil, station: "A",
                              scheduledDeparture: time, expectedDeparture: time, track: nil, cancelled: cancelled)
        }
        let connection = train("missed", minutes: 0)
        let options = [train("missed", minutes: 0), train("later", minutes: 60), train("cancelled", minutes: 30, cancelled: true), train("soon", minutes: 45)]
        let next = Handover.replacement(for: connection, in: options, after: missed.addingTimeInterval(5 * 60))
        #expect(next?.tripID == "soon")
        #expect(Handover.replacement(for: connection, in: [connection], after: missed) == nil)
    }

    @Test func replacementArrivesFirst() {
        // The RE leaves later than the S-Bahn but overtakes it.
        let base = utc("2026-06-12T16:00:00Z")
        func train(_ name: String, leaves: Double, arrives: Double) -> Connection {
            Connection(tripID: name, name: name, headsign: nil, station: "A",
                       scheduledDeparture: base.addingTimeInterval(leaves * 60), expectedDeparture: nil, track: nil,
                       finalArrival: base.addingTimeInterval(arrives * 60))
        }
        let options = [train("S 1 late", leaves: 88, arrives: 122), train("RE 1", leaves: 80, arrives: 107), train("S 1 later", leaves: 118, arrives: 152)]
        let next = Handover.replacement(for: train("RE 1 missed", leaves: 20, arrives: 47), in: options, after: base.addingTimeInterval(70 * 60))
        #expect(next?.name == "RE 1")
    }
}
