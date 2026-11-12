import Foundation
import Testing
@testable import ZugbarCore

struct YearReviewTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func trip(_ start: String, minutes: Double = 60, from: String = "A", to: String = "B", train: String = "ICE 1",
              distance: Double = 100, top: Int = 200, delay: Int? = nil) -> Trip {
        Trip(train: train, from: from, to: to, start: utc(start), end: utc(start).addingTimeInterval(minutes * 60),
             distance: distance, topSpeed: top, arrivalDelay: delay)
    }

    @Test func aYearWithoutTripsHasNoFigures() {
        let log = TripLog(trips: [trip("2031-03-01T10:00:00Z", delay: 2)])
        let review = log.review(year: 2030, calendar: calendar)
        #expect(review == YearReview(year: 2030))
        #expect(review.onTimeShare == nil)
        #expect(TripLog().years(calendar: calendar).isEmpty)
        #expect(TripLog().review(year: 2030, calendar: calendar).trips == 0)
    }

    @Test func addsUpAYear() {
        let log = TripLog(trips: [
            trip("2031-05-03T10:00:00Z", minutes: 90, distance: 150.5, top: 250, delay: 5),
            trip("2031-05-02T10:00:00Z", minutes: 45, from: "B", to: "C", train: "RE 2", distance: 40, top: 140, delay: 6),
            trip("2031-05-01T10:00:00Z", minutes: 30, from: "C", to: "D", train: "RE 3", distance: 20, top: 120, delay: -2),
        ])
        let review = log.review(year: 2031, calendar: calendar)
        #expect(review.trips == 3)
        #expect(abs(review.distance - 210.5) < 0.01)
        #expect(review.duration == 165 * 60)
        #expect(review.tripsWithDelay == 3)
        // 5 minutes late is still on time, 6 isn't; early arrivals don't lower the total.
        #expect(review.onTime == 2)
        #expect(review.onTimeShare == 2.0 / 3)
        #expect(review.delayMinutes == 11)
        #expect(review.fastest?.train == "ICE 1")
        #expect(review.mostRidden == nil)
    }

    @Test func tripsWithoutDelayDontCountForPunctuality() {
        let log = TripLog(trips: [
            trip("2031-05-03T10:00:00Z", delay: 10),
            trip("2031-05-02T10:00:00Z"),
            trip("2031-05-01T10:00:00Z"),
        ])
        let review = log.review(year: 2031, calendar: calendar)
        #expect(review.trips == 3)
        #expect(review.tripsWithDelay == 1)
        #expect(review.onTimeShare == 0)
        #expect(review.delayMinutes == 10)

        let unknown = TripLog(trips: [trip("2031-05-02T10:00:00Z")]).review(year: 2031, calendar: calendar)
        #expect(unknown.tripsWithDelay == 0)
        #expect(unknown.onTimeShare == nil)
        #expect(unknown.delayMinutes == 0)
    }

    @Test func aTripCountsForTheYearItStartedIn() {
        let log = TripLog(trips: [
            trip("2032-01-01T00:00:00Z", distance: 30),
            // Over midnight into the new year.
            trip("2031-12-31T23:30:00Z", minutes: 90, distance: 70),
            trip("2031-01-01T00:00:00Z", distance: 10),
            trip("2029-06-01T12:00:00Z", distance: 5),
        ])
        #expect(log.years(calendar: calendar) == [2032, 2031, 2029])
        #expect(log.review(year: 2031, calendar: calendar).trips == 2)
        #expect(log.review(year: 2031, calendar: calendar).distance == 80)
        #expect(log.review(year: 2032, calendar: calendar).distance == 30)
        #expect(log.review(year: 2030, calendar: calendar).trips == 0)

        // The year turns with the calendar's time zone, not UTC.
        var east = calendar
        east.timeZone = TimeZone(secondsFromGMT: 3600)!
        #expect(log.review(year: 2032, calendar: east).trips == 2)
    }

    @Test func mostRiddenPairCountsBothDirections() {
        let log = TripLog(trips: [
            trip("2031-05-06T10:00:00Z", from: "B", to: "A"),
            trip("2031-05-05T10:00:00Z", from: "C", to: "D"),
            trip("2031-05-04T10:00:00Z", from: "C", to: "D"),
            trip("2031-05-03T10:00:00Z", from: "A", to: "B"),
            trip("2031-05-02T10:00:00Z", from: "A", to: "B"),
            trip("2031-05-01T10:00:00Z", from: "?", to: "B"),
        ])
        // In the direction of the latest trip.
        #expect(log.review(year: 2031, calendar: calendar).mostRidden == YearReview.Pair(from: "B", to: "A", count: 3))

        // A tie goes to the pair ridden last, whatever the order in the log.
        let tied = TripLog(trips: Array(log.trips.dropFirst()))
        #expect(tied.review(year: 2031, calendar: calendar).mostRidden == YearReview.Pair(from: "C", to: "D", count: 2))
        #expect(TripLog(trips: tied.trips.reversed()).review(year: 2031, calendar: calendar).mostRidden?.from == "C")
    }

    @Test func noFastestTripWithoutASpeed() {
        let log = TripLog(trips: [trip("2031-05-01T10:00:00Z", top: 0)])
        #expect(log.review(year: 2031, calendar: calendar).fastest == nil)
    }
}
