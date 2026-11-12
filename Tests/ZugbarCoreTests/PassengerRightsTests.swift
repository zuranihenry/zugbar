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

    func plan(_ id: String = "8000002") -> JourneyPlan { JourneyPlan(trainName: "ICE 1", destinationStopID: id) }

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
        let late = try #require(PassengerRights.arrival(plan: plan(), status: status(delay: 60), now: now))
        #expect(late.refund == .quarter)
        #expect(late.delayMinutes == 60)
        #expect(late.stop == "B")
        #expect(PassengerRights.arrival(plan: plan(), status: status(delay: 125), now: now)?.refund == .half)
        // The same arrival seen again is the same hint.
        #expect(PassengerRights.arrival(plan: plan(), status: status(delay: 61), now: now)?.key == late.key)
    }

    @Test func saysNothingWithoutGrounds() {
        let now = planned.addingTimeInterval(3 * 3600)
        #expect(PassengerRights.arrival(plan: plan(), status: status(delay: 59), now: now) == nil)
        #expect(PassengerRights.arrival(plan: plan(), status: status(delay: nil), now: now) == nil)
        #expect(PassengerRights.arrival(plan: plan(), status: status(delay: 90, cancelled: true), now: now) == nil)
        // Outside the EU, or a stop whose country isn't known.
        #expect(PassengerRights.arrival(plan: plan("8500010"), status: status(delay: 90, id: "8500010"), now: now) == nil)
        #expect(PassengerRights.arrival(plan: plan("b"), status: status(delay: 90, id: "b"), now: now) == nil)
        // No destination, or another train's plan.
        #expect(PassengerRights.arrival(plan: nil, status: status(delay: 90), now: now) == nil)
        #expect(PassengerRights.arrival(plan: JourneyPlan(trainName: "ICE 2", destinationStopID: "8000002"), status: status(delay: 90), now: now) == nil)
    }

    @Test func notBeforeArriving() {
        // Still an hour and a half late, but half an hour out.
        let now = planned.addingTimeInterval(3600)
        #expect(PassengerRights.arrival(plan: plan(), status: status(delay: 90, passed: false), now: now) == nil)
        // Online, the live times get a moment's grace.
        let online = status(delay: 90, passed: false, provider: "Transitous")
        #expect(PassengerRights.arrival(plan: plan(), status: online, now: planned.addingTimeInterval(90 * 60 + 60)) == nil)
        #expect(PassengerRights.arrival(plan: plan(), status: online, now: planned.addingTimeInterval(90 * 60 + 180)) != nil)
    }

    @Test func aConnectionMeansTheJourneyGoesOn() {
        var plan = plan()
        plan.connection = Connection(tripID: "t", name: "RE 1", headsign: nil, station: "B", scheduledDeparture: nil, expectedDeparture: nil, track: nil)
        #expect(PassengerRights.arrival(plan: plan, status: status(delay: 90), now: planned.addingTimeInterval(3 * 3600)) == nil)
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
