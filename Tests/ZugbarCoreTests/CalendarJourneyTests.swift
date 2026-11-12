import Foundation
import Testing
@testable import ZugbarCore

/// Made-up events in the shapes bahn.de writes; no real trips.
struct CalendarJourneyTests {
    let start: Date = CalendarJourneyTests.local(10, 0)
    let twoLegs = """
        Astadt Hbf ➞ Cstadt
        Datum: 01.02.2026
        Klasse: Keine Information

        Astadt Hbf ➞ Bstadt Hbf
        ICE 123 (4567)
        ● ab 10:00 Astadt Hbf ▷ Gleis 4
        ○ an 11:30 Bstadt Hbf ▷ Gleis 12a

        Bstadt Hbf ➞ Cstadt
        RE5 (89012)
        ● ab 11:45 Bstadt Hbf ▷ Gleis 2
        ○ an 12:20 Cstadt ▷ Gleis 

        Dauer: 2h 20min
        ————
        Alle Angaben ohne Gewähr.
        """

    static func local(_ hour: Int, _ minute: Int, day: Int = 1) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 2, day: day, hour: hour, minute: minute))!
    }
    func local(_ hour: Int, _ minute: Int) -> Date { Self.local(hour, minute) }

    func journey(_ notes: String? = nil, title: String = "Astadt Hbf ➞ Cstadt", location: String? = "Astadt Hbf",
                 end: Date = local(12, 20)) -> CalendarJourney? {
        CalendarJourney(title: title, location: location, notes: notes ?? twoLegs, start: start, end: end)
    }

    func status(train: String = "ICE 123", arrival: Date = local(11, 30), passed: Bool = false) -> TrainStatus {
        TrainStatus(provider: "DB", trainName: train, stops: [
            Stop(id: "a", name: "Astadt Hbf", scheduledDeparture: local(10, 0), passed: true),
            Stop(id: "b", name: "Bstadt Hauptbahnhof", scheduledArrival: arrival, passed: passed),
            Stop(id: "d", name: "Dstadt", scheduledArrival: local(12, 40)),
        ], nextStopID: "b")
    }

    @Test func severalLegs() throws {
        let legs = try #require(journey()).legs
        #expect(legs == [
            .init(train: "ICE 123", alias: "ICE 4567", from: "Astadt Hbf", departure: local(10, 0), to: "Bstadt Hbf", arrival: local(11, 30)),
            .init(train: "RE 5", alias: "RE 89012", from: "Bstadt Hbf", departure: local(11, 45), to: "Cstadt", arrival: local(12, 20)),
        ])
    }

    @Test func directWithoutBracketsOrLocation() throws {
        let notes = """
            Astadt Hbf ➞ Bstadt Hbf
            Datum: 01.02.2026


            Astadt Hbf ➞ Bstadt Hbf
            ICE 123
            ● ab 10:00 Astadt Hbf ▷ Gleis 4
            ○ an 11:30 Bstadt Hbf ▷ Gleis 12
            """
        let found = try #require(journey(notes, title: "Astadt Hbf ➞ Bstadt Hbf", location: nil, end: local(11, 30)))
        #expect(found.legs.map(\.train) == ["ICE 123"])
        #expect(found.legs[0].alias == nil)
    }

    @Test func formerShape() throws {
        let notes = """
            Reise: Astadt Hbf nach Cstadt
            Datum: 01.02.26
            -
            ab 10:00 Astadt Hbf - Gleis 4 (ICE  123)
            an 11:30 Bstadt(Fluss)Hbf - Gleis 12 D-G

            ab 11:45 Bstadt(Fluss)Hbf (RE 89012)
            an 12:20 Cstadt
            -
            Dauer: 2:20 , Umsteigevorgänge 1
            """
        let legs = try #require(journey(notes, title: "Astadt Hbf -> Cstadt", location: nil)).legs
        #expect(legs.map(\.train) == ["ICE 123", "RE 89012"])
        #expect(legs.map(\.to) == ["Bstadt(Fluss)Hbf", "Cstadt"])
        #expect(legs[1].departure == local(11, 45))
    }

    @Test func overnight() throws {
        let notes = twoLegs.replacingOccurrences(of: "11:45", with: "23:50").replacingOccurrences(of: "12:20", with: "00:35")
        let legs = try #require(journey(notes, end: Self.local(0, 35, day: 2))).legs
        #expect(legs[1].arrival == Self.local(0, 35, day: 2))
    }

    @Test func nearMisses() {
        // Event times that aren't the journey's.
        #expect(journey(end: local(13, 0)) == nil)
        #expect(CalendarJourney(title: "Astadt Hbf ➞ Cstadt", notes: twoLegs, start: local(9, 0), end: local(12, 20)) == nil)
        // A title or location about somewhere else.
        #expect(journey(title: "Astadt Hbf ➞ Dstadt") == nil)
        #expect(journey(location: "Büro") == nil)
        // Legs that don't join up, lack a train or an arrival.
        #expect(journey(twoLegs.replacingOccurrences(of: "ab 11:45 Bstadt Hbf", with: "ab 11:45 Xstadt")) == nil)
        #expect(journey(twoLegs.replacingOccurrences(of: "ICE 123 (4567)", with: "Mit dem Zug")) == nil)
        #expect(journey(twoLegs.replacingOccurrences(of: "○ an 11:30 Bstadt Hbf ▷ Gleis 12a\n", with: "")) == nil)
        #expect(journey(twoLegs.replacingOccurrences(of: "Datum: 01.02.2026\n", with: "")) == nil)
        // An arrow of another kind, as someone typing it themselves would.
        #expect(journey(title: "Astadt Hbf → Cstadt") == nil)
    }

    @Test func handWrittenLookalikes() {
        let former = """
            Reise: Astadt Hbf nach Cstadt
            Datum: 01.02.26
            -
            ab 10:00 Astadt Hbf (ICE 123)
            an 12:20 Cstadt
            """
        func parsed(_ notes: String) -> CalendarJourney? {
            CalendarJourney(title: "Astadt Hbf -> Cstadt", notes: notes, start: start, end: local(12, 20))
        }
        #expect(parsed(former) != nil)
        // A flight, a taxi or a bus laid out the same way.
        #expect(parsed(former.replacingOccurrences(of: "ICE 123", with: "LH 123")) == nil)
        #expect(parsed(former.replacingOccurrences(of: "ICE 123", with: "Taxi 1")) == nil)
        #expect(journey(twoLegs.replacingOccurrences(of: "RE5 (89012)", with: "Bus 647")) == nil)
        // A date that isn't one, or isn't the event's day.
        #expect(parsed(former.replacingOccurrences(of: "01.02.26", with: "offen")) == nil)
        #expect(parsed(former.replacingOccurrences(of: "01.02.26", with: "02.02.26")) == nil)
        #expect(journey(twoLegs.replacingOccurrences(of: "01.02.2026", with: "01.03.2026")) == nil)
    }

    @Test func switchStaysOffWithoutPermission() {
        // Taken away while the app wasn't running: off, and still off once it's granted again.
        #expect(!CalendarSwitch(saved: true, permission: .refused).isOn)
        #expect(!CalendarSwitch(saved: true, permission: .notAsked).isOn)
        #expect(!CalendarSwitch(saved: false, permission: .granted).isOn)
        #expect(CalendarSwitch(saved: true, permission: .granted).isOn)

        var refused = CalendarSwitch(saved: false, permission: .refused)
        #expect(refused.turnOn(permission: .refused) == .openSystemSettings)
        #expect(!refused.isOn)
    }

    @Test func switchedOffWhileThePromptIsOpen() {
        var state = CalendarSwitch(saved: false, permission: .notAsked)
        #expect(state.turnOn(permission: .notAsked) == .ask)
        #expect(!state.isOn)
        state.turnOff()
        state.answered(granted: true)
        #expect(!state.isOn)

        #expect(state.turnOn(permission: .notAsked) == .ask)
        state.answered(granted: true)
        #expect(state.isOn)
        #expect(state.turnOn(permission: .notAsked) == .ask)
        state.answered(granted: false)
        #expect(!state.isOn)
    }

    @Test func unrelatedEvents() {
        #expect(CalendarJourney(title: "Zahnarzt", location: "Praxis", notes: nil, start: start, end: local(11, 0)) == nil)
        #expect(CalendarJourney(title: "Team -> Planung", notes: "Datum: offen\nab 10:00 Raum 2", start: start, end: local(11, 0)) == nil)
        #expect(CalendarJourney(title: "Astadt Hbf ➞ Cstadt", notes: "Zug nach Cstadt, ICE 123, ab 10:00", start: start, end: local(12, 20)) == nil)
        #expect(CalendarJourney(title: "", notes: "", start: start, end: start) == nil)
    }

    @Test func suggestsStopAndConnection() throws {
        let found = try #require(journey())
        let suggestion = try #require(found.suggestion(for: status(), plan: nil, now: local(10, 30)))
        #expect(suggestion.stopID == "b")
        #expect(suggestion.setsStop)
        #expect(suggestion.onward == .init(train: "RE 5", alias: "RE 89012", departure: local(11, 45), to: "Cstadt"))
        // Named by the number in brackets, as some portals do.
        #expect(found.suggestion(for: status(train: "ICE 4567"), plan: nil, now: local(10, 30)) != nil)
    }

    @Test func suggestsNothingForOtherTrainsOrTimes() throws {
        let found = try #require(journey())
        #expect(found.suggestion(for: status(train: "ICE 321"), plan: nil, now: local(10, 30)) == nil)
        // The same number at another time of day, a stop already behind, or the journey over.
        #expect(found.suggestion(for: status(arrival: local(15, 30)), plan: nil, now: local(10, 30)) == nil)
        #expect(found.suggestion(for: status(passed: true), plan: nil, now: local(10, 30)) == nil)
        #expect(found.suggestion(for: status(), plan: nil, now: local(11, 31)) == nil)
    }

    @Test func leavesTheUsersPlanAlone() throws {
        let found = try #require(journey())
        let now = local(10, 30)
        // Another stop chosen by hand.
        #expect(found.suggestion(for: status(), plan: JourneyPlan(trainName: "ICE 123", destinationStopID: "d"), now: now) == nil)
        // The same stop: only the connection is offered, and not once there is one.
        var plan = JourneyPlan(trainName: "ICE 123", destinationStopID: "b")
        let suggestion = try #require(found.suggestion(for: status(), plan: plan, now: now))
        #expect(!suggestion.setsStop)
        #expect(suggestion.onward?.train == "RE 5")
        plan.connection = connection("RE 5", at: local(11, 45))
        #expect(found.suggestion(for: status(), plan: plan, now: now) == nil)
        // On the last train of the journey there's a stop but nothing after it.
        let last = TrainStatus(provider: "DB", trainName: "RE 5 (89012)", stops: [Stop(id: "c", name: "Cstadt", scheduledArrival: local(12, 20))])
        #expect(found.suggestion(for: last, plan: nil, now: now)?.onward == nil)
    }

    func connection(_ name: String, at departure: Date) -> Connection {
        Connection(tripID: name + departure.description, name: name, headsign: nil, station: "Bstadt Hbf",
                   scheduledDeparture: departure, expectedDeparture: nil, track: nil)
    }

    @Test func picksTheBookedConnection() {
        let onward = CalendarJourney.Onward(train: "RE 5", alias: "RE 89012", departure: local(11, 45), to: "Cstadt")
        let booked = connection("RE 5", at: local(11, 45)), later = connection("RE 5", at: local(12, 45))
        #expect(onward.pick(from: [later, booked]) == booked)
        #expect(onward.pick(from: [later]) == nil)
        // Named differently: only when it's the one train leaving that minute.
        let other = connection("RB 7", at: local(11, 45))
        #expect(onward.pick(from: [other, later]) == other)
        #expect(onward.pick(from: [other, connection("S 1", at: local(11, 45))]) == nil)
    }
}
