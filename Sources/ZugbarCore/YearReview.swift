import Foundation

/// A year of trips in figures, for the Trips tab. Figures without data are `nil` or zero and left out there.
public struct YearReview: Sendable, Equatable {
    /// Two stations ridden between, in either direction.
    public struct Pair: Sendable, Equatable {
        /// In the direction of the latest trip between the two.
        public var from: String
        public var to: String
        public var count: Int
    }

    /// Arriving less than this many minutes late is on time, as the railway counts it.
    public static let onTimeBelow = 6

    public var year: Int
    public var trips = 0
    /// Kilometers.
    public var distance = 0.0
    public var duration: TimeInterval = 0
    /// Trips whose arrival delay is known: the only ones the punctuality and the delay total can speak for.
    public var tripsWithDelay = 0
    public var onTime = 0
    /// Minutes late in total; arriving early doesn't make up for it.
    public var delayMinutes = 0
    /// The trip with the highest top speed, when any had one.
    public var fastest: Trip?
    /// The pair ridden most, when one was ridden more than once.
    public var mostRidden: Pair?

    /// Percent of trips on time, rounded down so that 100 means every one of them; `nil` when no trip's delay is known.
    public var onTimePercent: Int? {
        tripsWithDelay > 0 ? onTime * 100 / tripsWithDelay : nil
    }

    /// Gregorian in the current time zone: the user's own calendar may count years by era, where two years
    /// decades apart share a number.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

extension TripLog {
    /// The years with trips, latest first. A trip counts for the year it started in.
    public func years(calendar: Calendar = YearReview.calendar) -> [Int] {
        Set(trips.map { calendar.component(.year, from: $0.start) }).sorted(by: >)
    }

    public func review(year: Int, calendar: Calendar = YearReview.calendar) -> YearReview {
        let trips = trips.filter { calendar.component(.year, from: $0.start) == year }
        var review = YearReview(year: year)
        review.trips = trips.count
        review.distance = trips.map(\.distance).reduce(0, +)
        review.duration = trips.map(\.duration).reduce(0, +)
        let delays = trips.compactMap(\.arrivalDelay)
        review.tripsWithDelay = delays.count
        review.onTime = delays.count { $0 < YearReview.onTimeBelow }
        review.delayMinutes = delays.map { max($0, 0) }.reduce(0, +)
        // Among equals the later trip, so the result doesn't hang on the order in the log.
        review.fastest = trips.filter { $0.topSpeed > 0 }
            .max { ($0.topSpeed, $0.start) < ($1.topSpeed, $1.start) }
        review.mostRidden = Self.mostRidden(trips)
        return review
    }

    private static func mostRidden(_ trips: [Trip]) -> YearReview.Pair? {
        struct Tally { var count = 0; var latest: Trip }
        var pairs: [[String]: Tally] = [:]
        // "?" stands for a stop the portal didn't name.
        for trip in trips where trip.from != trip.to && trip.from != "?" && trip.to != "?" {
            let key = [trip.from, trip.to].sorted()
            var tally = pairs[key] ?? Tally(latest: trip)
            tally.count += 1
            if trip.start > tally.latest.start { tally.latest = trip }
            pairs[key] = tally
        }
        guard let top = pairs.values.max(by: { ($0.count, $0.latest.start) < ($1.count, $1.latest.start) }), top.count > 1
        else { return nil }
        return YearReview.Pair(from: top.latest.from, to: top.latest.to, count: top.count)
    }
}
