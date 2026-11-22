import Foundation
import Testing
@testable import ZugbarCore

/// Made-up connections in the shape DB Navigator shares them; no real trips.
struct SharedJourneyTests {
    static let zone = TimeZone(identifier: "Europe/Berlin")!
    let threeTrains = """
        Astadt Hbf → Dstadt
        01.02.2026

        RE1 (4567)
        Nach Bad Xstadt
        Ab 10:00 Astadt Hbf, Gleis 4 A-C
        An 11:05 Bstadt, Gleis 3

        RE2 (8901)
        Nach Ystadt Hbf
        Ab 11:17 Bstadt, Gleis 5
        An 12:07 Cstadt Hbf, Gleis 1 A-B

        RE3 (2345)
        Nach Zstadt(Fluss)Hbf
        Ab 12:14 Cstadt Hbf, Gleis 2
        An 12:35 Dstadt, Gleis 1

        Verbindung ansehen:
        https://www.example.com/start?vbid=00000000%2D0000
        """

    static func local(_ hour: Int, _ minute: Int, day: Int = 1) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 2, day: day, hour: hour, minute: minute))!
    }
    func local(_ hour: Int, _ minute: Int, day: Int = 1) -> Date { Self.local(hour, minute, day: day) }

    func journey(_ text: String? = nil, now: Date = local(9, 0)) -> SharedJourney? {
        SharedJourney(text: text ?? threeTrains, now: now, timeZone: Self.zone)
    }

    /// The first train as its portal shows it, between the two stops of the journey.
    func status(train: String = "RE1 (4567)", arrival: Date = local(11, 5), passed: Bool = false) -> TrainStatus {
        TrainStatus(provider: "DB", trainName: train, stops: [
            Stop(id: "a", name: "Astadt Hauptbahnhof", scheduledDeparture: local(10, 0), passed: true),
            Stop(id: "m", name: "Mstadt", scheduledArrival: local(10, 30)),
            Stop(id: "b", name: "Bstadt", scheduledArrival: arrival, passed: passed),
            Stop(id: "x", name: "Bad Xstadt", scheduledArrival: local(11, 40)),
        ])
    }

    @Test func readsTheTrainsInOrder() throws {
        let legs = try #require(journey()).legs
        #expect(legs.map(\.train) == ["RE1 (4567)", "RE2 (8901)", "RE3 (2345)"])
        #expect(legs.map(\.from) == ["Astadt Hbf", "Bstadt", "Cstadt Hbf"])
        #expect(legs.map(\.to) == ["Bstadt", "Cstadt Hbf", "Dstadt"])
        #expect(legs.map(\.departure) == [local(10, 0), local(11, 17), local(12, 14)])
        #expect(legs.map(\.arrival) == [local(11, 5), local(12, 7), local(12, 35)])
        // Station names as the app writes them everywhere.
        #expect(legs.map(\.headsign) == ["Bad Xstadt", "Ystadt Hbf", "Zstadt(Fluss) Hbf"])
        // The track without where on it the train stops.
        #expect(legs.map(\.departureTrack) == ["4", "5", "2"])
    }

    @Test func readsVariationsOfTheText() throws {
        // No tracks, no "Nach" line, a two-digit year, Windows line ends.
        let plain = "Astadt → Bstadt\r\n01.02.26\r\n\r\nICE 123\r\nAb 23:40 Astadt\r\nAn 00:25 Bstadt\r\n"
        let leg = try #require(journey(plain)?.legs.first)
        #expect(leg.train == "ICE 123" && leg.headsign == nil && leg.departureTrack == nil)
        #expect(leg.departure == local(23, 40))
        // Past midnight is the next day.
        #expect(leg.arrival == local(0, 25, day: 2))

        // Without a date line the journey starts today.
        let undated = try #require(journey("S 3\nAb 10:00 Astadt\nAn 10:20 Bstadt", now: local(9, 0, day: 5)))
        #expect(undated.legs[0].departure == local(10, 0, day: 5))
    }

    @Test func leavesOutWhatIsNotATrain() throws {
        let withBus = """
            Astadt Hbf → Cstadt
            01.02.2026

            RE1 (4567)
            Nach Bad Xstadt
            Ab 10:00 Astadt Hbf, Gleis 4
            An 11:05 Bstadt, Gleis 3

            Bus 40
            Nach Bstadt Markt
            Ab 11:10 Bstadt
            An 11:20 Bstadt Markt

            Fußweg
            Ab 11:20 Bstadt Markt
            An 11:25 Bstadt Nord

            RB 7
            Ab 11:40 Bstadt Nord, Gleis 1
            An 12:00 Cstadt
            """
        let legs = try #require(journey(withBus)).legs
        #expect(legs.map(\.train) == ["RE1 (4567)", "RB 7"])
        // The next train starts where it starts, and at its own time.
        #expect(legs[1].from == "Bstadt Nord" && legs[1].departure == local(11, 40))
    }

    @Test func otherTextIsNoConnection() {
        #expect(journey("") == nil)
        #expect(journey("Ab morgen bin ich im Urlaub.\nAn alle: bis dann!") == nil)
        #expect(journey("https://www.example.com/start?vbid=0000") == nil)
        // A departure without the arrival below it.
        #expect(journey("RE 1\nAb 10:00 Astadt, Gleis 1") == nil)
        // A time no clock shows.
        #expect(journey("RE 1\nAb 25:00 Astadt\nAn 26:00 Bstadt") == nil)
        // Only a bus.
        #expect(journey("Bus 40\nAb 10:00 Astadt\nAn 10:20 Bstadt") == nil)
        #expect(journey(String(repeating: "RE 1\nAb 10:00 Astadt\nAn 10:20 Bstadt\n", count: 1000)) == nil)
    }

    @Test func trainsBecomeConnectionsKnownByName() throws {
        let leg = try #require(journey()?.legs[1])
        let connection = leg.connection
        #expect(connection.name == "RE2 (8901)" && connection.station == "Bstadt" && connection.finalStop == "Cstadt Hbf")
        #expect(connection.scheduledDeparture == local(11, 17) && connection.track == "5")
        #expect(connection.finalArrival == local(12, 7) && connection.scheduledFinalArrival == local(12, 7))
        #expect(connection.isShared)
        // Followed by name until its trip is known, and not refreshed as a trip.
        #expect(Handover.target(for: connection) == .name("RE2 (8901)"))

        // Found on the departure board: the trip with its live times, the journey's own stops kept.
        let board = [
            TransitousClient.Departure(tripID: "other", displayName: "RE2 (8903)", line: "RE2", headsign: "Astadt Hbf",
                                       scheduled: local(11, 47), expected: nil, track: "4", cancelled: false, realTime: false),
            TransitousClient.Departure(tripID: "trip-re2", displayName: "RE2 (8901)", line: "RE2", headsign: "Ystadt Hbf",
                                       scheduled: local(11, 17), expected: local(11, 21), track: "6", cancelled: false, realTime: true),
        ]
        let departure = try #require(Handover.departure(for: connection, in: board))
        let resolved = connection.resolved(with: departure)
        #expect(resolved.tripID == "trip-re2" && !resolved.isShared)
        #expect(resolved.delayMinutes == 4 && resolved.track == "6")
        #expect(resolved.station == "Bstadt" && resolved.finalStop == "Cstadt Hbf" && resolved.finalArrival == local(12, 7))
        #expect(Handover.target(for: resolved) == .trip(id: "trip-re2", label: "RE2 (8901) → Ystadt Hbf"))
        // A board that knows the train by its line alone: the number shared with it stays.
        let byLine = TransitousClient.Departure(tripID: "trip-re2", displayName: "RE2", line: "RE2", headsign: nil,
                                                scheduled: local(11, 17), expected: nil, track: nil, cancelled: false, realTime: false)
        #expect(Handover.departure(for: connection, in: [byLine]) == byLine)
        let kept = connection.resolved(with: byLine)
        #expect(kept.name == "RE2 (8901)" && kept.headsign == "Ystadt Hbf" && kept.track == "5")
        #expect(TrainName.same(kept.name, "RE2") && TrainName.same(kept.name, "RE 2 (8901)"))
    }

    @Test func planForTheTrainTheUserIsOn() throws {
        let journey = try #require(journey())
        let plan = try #require(journey.plan(on: status(), previous: nil, now: local(10, 10)))
        #expect(plan.trainName == "RE1 (4567)")
        #expect(plan.boardingStopID == "a" && plan.destinationStopID == "b")
        #expect(plan.route.map(\.name) == ["RE2 (8901)", "RE3 (2345)"])
        #expect(plan.finalStop == "Dstadt")
        #expect(plan.plannedArrival == local(12, 35))

        // The coach entered before and the time on board stay.
        var previous = JourneyPlan(trainName: "RE1 (4567)", boardingStopID: "m")
        previous.seat = Seat(coach: "3")
        previous.boarded = local(10, 5)
        let kept = try #require(journey.plan(on: status(), previous: previous, now: local(10, 10)))
        #expect(kept.seat == Seat(coach: "3") && kept.boarded == local(10, 5) && kept.boardingStopID == "m")

        // A portal that names the train by its line alone: the stops at the journey's very times say it's the one.
        #expect(journey.plan(on: status(train: "RE 1"), previous: nil, now: local(10, 10))?.destinationStopID == "b")
        // The same line an hour later isn't.
        #expect(journey.plan(on: status(train: "RE 1", arrival: local(12, 5)), previous: nil, now: local(10, 10)) == nil)
        // Another train, a stop already behind it, or the same number on another day.
        #expect(journey.plan(on: status(train: "ICE 9"), previous: nil, now: local(10, 10))?.trainName == "ICE 9")
        #expect(journey.plan(on: status(train: "ICE 9", arrival: local(11, 20)), previous: nil, now: local(10, 10)) == nil)
        #expect(journey.plan(on: status(passed: true), previous: nil, now: local(11, 10)) == nil)
        #expect(journey.plan(on: status(arrival: local(11, 5, day: 2)), previous: nil, now: local(10, 10)) == nil)

        // On the second train: only the third is left to change to.
        let second = TrainStatus(provider: "Transitous", trainName: "RE2 (8901)", stops: [
            Stop(id: "b", name: "Bstadt", scheduledDeparture: local(11, 17)),
            Stop(id: "c", name: "Cstadt Hbf", scheduledArrival: local(12, 7)),
        ])
        let onSecond = try #require(journey.plan(on: second, previous: nil, now: local(11, 20)))
        #expect(onSecond.destinationStopID == "c" && onSecond.route.map(\.name) == ["RE3 (2345)"])
    }

    @Test func startsWithTheNextTrainToArrive() throws {
        let journey = try #require(journey())
        let early = try #require(journey.start(at: local(9, 0)))
        #expect(early.train.name == "RE1 (4567)")
        #expect(early.plan.trainName == "RE1 (4567)")
        #expect(early.plan.pendingBoarding == "Astadt Hbf" && early.plan.pendingDestination == "Bstadt")
        #expect(early.plan.route.map(\.name) == ["RE2 (8901)", "RE3 (2345)"])
        #expect(early.plan.plannedArrival == local(12, 35))

        // Taken between two trains: the first one is behind the user.
        let between = try #require(journey.start(at: local(11, 10)))
        #expect(between.train.name == "RE2 (8901)" && between.plan.route.map(\.name) == ["RE3 (2345)"])
        let last = try #require(journey.start(at: local(12, 20)))
        #expect(last.train.name == "RE3 (2345)" && last.plan.route.isEmpty)
        #expect(journey.start(at: local(12, 40)) == nil)

        // Its stops are found once the train's own list is known.
        let resolved = early.plan.resolved(in: status())
        #expect(resolved.boardingStopID == "a" && resolved.destinationStopID == "b")
    }

    @Test func findsATrainsTripOnTheDepartureBoard() async throws {
        let asked = URLBox()
        let client = TransitousClient { url in
            await asked.set(url)
            return url.path.hasSuffix("geocode")
                ? Data(#"[{"id":"de-1","name":"Bstadt Bahnhof","modes":["REGIONAL_RAIL"]}]"#.utf8)
                : Data(#"{"stopTimes":[]}"#.utf8)
        }
        let connection = try #require(journey()?.legs[1].connection)
        #expect(try await client.departure(for: connection) == nil)
        // Trains only, from just before it leaves.
        let query = try #require(await asked.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        #expect(query.first { $0.name == "mode" }?.value?.contains("REGIONAL_RAIL") == true)
        #expect(query.first { $0.name == "stopId" }?.value == "de-1")
    }
}
