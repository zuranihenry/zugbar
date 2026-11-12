import Foundation
import Testing
@testable import ZugbarCore

struct PassengerRightsTests {
    let planned = utc("2026-06-12T16:00:00Z")

    func status(delay: Int?, id: String = "8000002", cancelled: Bool = false, passed: Bool = true, provider: String = "Deutsche Bahn") -> TrainStatus {
        TrainStatus(provider: provider, trainName: "ICE 1", stops: [
            Stop(id: "8000001", name: "A", scheduledDeparture: planned.addingTimeInterval(-3600), passed: true),
            Stop(id: id, name: "B", scheduledArrival: planned,
                 expectedArrival: delay.map { planned.addingTimeInterval(Double($0) * 60) }, passed: passed, cancelled: cancelled),
        ])
    }

    /// A plan for a journey the user is on board for.
    func plan(_ id: String = "8000002", train: String = "ICE 1") -> JourneyPlan {
        var plan = JourneyPlan(trainName: train, destinationStopID: id)
        plan.boarded = planned.addingTimeInterval(-3600)
        return plan
    }

    func arrival(_ plan: JourneyPlan?, _ status: TrainStatus, now: Date, seen: Date? = nil) -> PassengerRights.Arrival? {
        PassengerRights.arrival(plan: plan, status: status, seen: seen ?? now, now: now)
    }

    @Test func thresholds() {
        #expect(PassengerRights.refund(delayMinutes: 59) == nil)
        #expect(PassengerRights.refund(delayMinutes: 60) == .quarter)
        #expect(PassengerRights.refund(delayMinutes: 119) == .quarter)
        #expect(PassengerRights.refund(delayMinutes: 120) == .half)
        #expect(PassengerRights.refund(delayMinutes: nil) == nil)
        #expect(PassengerRights.refund(delayMinutes: 150, cancelled: true) == nil)
        #expect(PassengerRights.Refund.quarter.rawValue == 25)
        #expect(PassengerRights.Refund.half.rawValue == 50)
    }

    @Test func countryFromStopID() {
        #expect(PassengerRights.country(ofStopID: "8000002") == "de")
        #expect(PassengerRights.country(ofStopID: "8000002_1") == "de")
        #expect(PassengerRights.country(ofStopID: "8500010") == "ch")
        #expect(PassengerRights.country(ofStopID: "FRABC") == "fr")
        #expect(PassengerRights.country(ofStopID: "4-de-DELFI_de:00000:100") == "de")
        #expect(PassengerRights.country(ofStopID: "4-de-DELFI_ch:1:sloid:1") == "ch")
        #expect(PassengerRights.country(ofStopID: "0-be-feed_8000002") == "de")
        #expect(PassengerRights.country(ofStopID: "2-nl-feed_abc") == "nl")
        #expect(PassengerRights.country(ofStopID: "B") == nil)
        #expect(PassengerRights.country(ofStopID: "3-Somewhere") == nil)
    }

    @Test func onlyInTheEU() {
        #expect(PassengerRights.applies(at: Stop(id: "8100002", name: "B")))
        #expect(!PassengerRights.applies(at: Stop(id: "8500010", name: "B")))
        #expect(!PassengerRights.applies(at: Stop(id: "7000001", name: "B")))
        #expect(!PassengerRights.applies(at: Stop(id: "b", name: "B")))
    }

    @Test func hintsOnceArrivedLate() throws {
        let now = planned.addingTimeInterval(3 * 3600)
        let late = try #require(arrival(plan(), status(delay: 60), now: now))
        #expect(late.refund == .quarter)
        #expect(late.delayMinutes == 60)
        #expect(late.stop == "B")
        #expect(arrival(plan(), status(delay: 125), now: now)?.refund == .half)
        // The same arrival seen again is the same hint.
        #expect(arrival(plan(), status(delay: 61), now: now)?.key == late.key)
    }

    @Test func saysNothingWithoutGrounds() {
        let now = planned.addingTimeInterval(3 * 3600)
        #expect(arrival(plan(), status(delay: 59), now: now) == nil)
        #expect(arrival(plan(), status(delay: nil), now: now) == nil)
        #expect(arrival(plan(), status(delay: 90, cancelled: true), now: now) == nil)
        // Outside the EU, or a stop whose country isn't known.
        #expect(arrival(plan("8500010"), status(delay: 90, id: "8500010"), now: now) == nil)
        #expect(arrival(plan("b"), status(delay: 90, id: "b"), now: now) == nil)
        // No destination, or another train's plan.
        #expect(arrival(nil, status(delay: 90), now: now) == nil)
        #expect(arrival(plan(train: "ICE 2"), status(delay: 90), now: now) == nil)
    }

    @Test func notBeforeArriving() {
        // Still an hour and a half late, but half an hour out.
        let now = planned.addingTimeInterval(3600)
        #expect(arrival(plan(), status(delay: 90, passed: false), now: now) == nil)
        // Online, the live times get a moment's grace.
        let online = status(delay: 90, passed: false, provider: "Transitous")
        #expect(arrival(plan(), online, now: planned.addingTimeInterval(90 * 60 + 60)) == nil)
        #expect(arrival(plan(), online, now: planned.addingTimeInterval(90 * 60 + 180)) != nil)
    }

    @Test func aConnectionMeansTheJourneyGoesOn() {
        var plan = plan()
        plan.connection = Connection(tripID: "t", name: "RE 1", headsign: nil, station: "B", scheduledDeparture: nil, expectedDeparture: nil, track: nil)
        #expect(arrival(plan, status(delay: 90), now: planned.addingTimeInterval(3 * 3600)) == nil)
    }

    @Test func aMissedConnectionCountsFromTheFirstPlan() throws {
        // The first train was late, the connection gone; the replacement runs on time but gets in 65 minutes
        // after the journey was planned to end.
        var first = JourneyPlan(trainName: "ICE 9", destinationStopID: "8000001")
        first.boarded = planned.addingTimeInterval(-3 * 3600)
        var missed = Connection(tripID: "t1", name: "RE 1", headsign: nil, station: "A", scheduledDeparture: nil, expectedDeparture: nil,
                                track: nil, finalStop: "B")
        missed.scheduledFinalArrival = planned.addingTimeInterval(-65 * 60)
        first.connection = missed
        first.plannedArrival = first.timetabledArrival(in: nil)
        var next = Connection(tripID: "t2", name: "ICE 1", headsign: nil, station: "A", scheduledDeparture: nil, expectedDeparture: nil,
                              track: nil, finalStop: "B")
        next.scheduledFinalArrival = planned
        first.connection = next
        #expect(first.plannedArrival == missed.scheduledFinalArrival)

        let onward = Handover.plan(after: next, from: first, now: planned).resolved(in: status(delay: 0))
        #expect(onward.destinationStopID == "8000002")
        let late = try #require(arrival(onward, status(delay: 0), now: planned.addingTimeInterval(600)))
        #expect(late.delayMinutes == 65)
        #expect(late.refund == .quarter)
        // Without the first plan there's only the punctual train to go by.
        #expect(arrival(Handover.plan(after: next, now: planned).resolved(in: status(delay: 0)), status(delay: 0),
                        now: planned.addingTimeInterval(600)) == nil)
    }

    @Test func aPlanFromAnotherDayDoesNotCount() {
        var stale = plan()
        stale.plannedArrival = planned.addingTimeInterval(-24 * 3600)
        #expect(arrival(stale, status(delay: 0), now: planned.addingTimeInterval(600)) == nil)
        stale = plan()
        stale.boarded = planned.addingTimeInterval(-24 * 3600)
        #expect(arrival(stale, status(delay: 90), now: planned.addingTimeInterval(3 * 3600)) == nil)
    }

    @Test func sameJourneySameKeyWhateverTheSource() throws {
        let now = planned.addingTimeInterval(3 * 3600)
        var plan = plan()
        plan.plannedArrival = planned
        let onBoard = try #require(arrival(plan, status(delay: 70), now: now))
        // Followed online after getting off: other spellings of train and station, other stop IDs.
        var online = TrainStatus(provider: "Transitous", trainName: "ICE1", stops: [
            Stop(id: "1-de-feed_de:00000:2", name: "B (main station)", scheduledArrival: planned.addingTimeInterval(30),
                 expectedArrival: planned.addingTimeInterval(72 * 60)),
        ])
        online.stops[0].passed = true
        plan.destinationStopID = online.stops[0].id
        let later = try #require(arrival(plan, online, now: now))
        #expect(later.key == onBoard.key)
        #expect(later.stop != onBoard.stop)
    }

    @Test func notForATrainOnlyWatched() {
        let now = planned.addingTimeInterval(3 * 3600)
        let watched = JourneyPlan(trainName: "ICE 1", destinationStopID: "8000002")
        #expect(arrival(watched, status(delay: 90, provider: "Transitous"), now: now) == nil)
        #expect(arrival(watched, status(delay: 90), now: now) == nil)
        // Seen on board once: the plan remembers, also when the train is followed online afterwards.
        var ridden = watched
        ridden.noteOnBoard(at: planned)
        #expect(arrival(ridden, status(delay: 90, provider: "Transitous"), now: now) != nil)
        // Noted again only after a while.
        ridden.noteOnBoard(at: planned.addingTimeInterval(60))
        #expect(ridden.boarded == planned)
        ridden.noteOnBoard(at: planned.addingTimeInterval(601))
        #expect(ridden.boarded == planned.addingTimeInterval(601))
    }

    @Test func anArrivalNotSeenIsMarkedSo() throws {
        // Last heard from half an hour before a 90 minutes late arrival, then nothing until long after.
        let seen = planned.addingTimeInterval(60 * 60), now = planned.addingTimeInterval(5 * 3600)
        let late = try #require(arrival(plan(), status(delay: 90, passed: false), now: now, seen: seen))
        #expect(!late.observed)
        #expect(try #require(arrival(plan(), status(delay: 90), now: now)).observed)
        #expect(try #require(arrival(plan(), status(delay: 90, passed: false, provider: "Transitous"), now: now)).observed)
    }

    @Test func tripsRememberWhetherTheRuleApplied() {
        var trip = Trip(train: "ICE 1", from: "A", to: "B", start: planned, end: planned, distance: 100, topSpeed: 200, arrivalDelay: 130)
        // Logged before this was noted.
        #expect(trip.refund == nil)
        trip.passengerRights = true
        #expect(trip.refund == .half)
        trip.arrivalDelay = 20
        #expect(trip.refund == nil)
        trip.arrivalDelay = 70
        trip.passengerRights = false
        #expect(trip.refund == nil)
    }
}
