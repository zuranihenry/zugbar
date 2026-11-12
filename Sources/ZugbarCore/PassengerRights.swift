import Foundation

/// The EU's rail passenger rights (Regulation 2021/782), as far as the app can judge them: a share of the fare
/// back for arriving late at the journey's destination. The app knows neither the ticket nor whether the journey
/// went on, so this is only ever a hint.
public enum PassengerRights {
    /// The share of the fare, in percent.
    public enum Refund: Int, Sendable, Equatable {
        case quarter = 25
        case half = 50
    }

    /// What a delay at the destination may be worth: a quarter from 60 minutes, half from 120. Nothing when the
    /// delay isn't known, or the train didn't stop there after all.
    public static func refund(delayMinutes: Int?, cancelled: Bool = false) -> Refund? {
        guard !cancelled, let delayMinutes, delayMinutes >= 60 else { return nil }
        return delayMinutes >= 120 ? .half : .quarter
    }

    /// Whether `stop` is in the EU, going by its ID. Unknown IDs count as outside: better no hint than a wrong one.
    public static func applies(at stop: Stop) -> Bool {
        country(ofStopID: stop.id).map(euCountries.contains) ?? false
    }

    /// A late arrival at the end of the planned journey.
    public struct Arrival: Sendable, Equatable {
        public var stop: String
        public var delayMinutes: Int
        public var refund: Refund
        /// Whether the train was seen at or after its arrival; otherwise the delay is the last one known before.
        public var observed: Bool
        /// The same for this journey whichever train or source reports its end, so it's hinted at once.
        public var key: String
    }

    /// How far back the user being on board, or the journey's planned arrival, still belongs to this arrival:
    /// a plan can come back when the same train number runs again another day.
    static let journeySpan: TimeInterval = 18 * 3600

    /// The refund that may be due once the followed train has reached the plan's destination, counted from when
    /// the journey was first planned to end. Not while a connection is planned: the journey ends where that one
    /// does, and its train is followed next. Only for a journey the user was on board for, not a train merely
    /// watched. `seen` is when `status` was fetched.
    public static func arrival(plan: JourneyPlan?, status: TrainStatus, seen: Date, now: Date) -> Arrival? {
        guard let plan, plan.connection == nil, let train = status.trainName, TrainName.same(plan.trainName, train),
              let stop = status.stops.first(where: { $0.id == plan.destinationStopID }), applies(at: stop),
              let arrival = stop.arrival, let boarded = plan.boarded, abs(arrival.timeIntervalSince(boarded)) < journeySpan
        else { return nil }
        let planned = plan.plannedArrival.flatMap { abs(arrival.timeIntervalSince($0)) < journeySpan ? $0 : nil }
            ?? stop.scheduledArrival
        guard let planned, let refund = refund(delayMinutes: minutes(from: planned, to: arrival), cancelled: stop.cancelled)
        else { return nil }
        // Online the live times can lag the train; on board the portal says when the stop is behind it, and
        // whether the train is still rolling in, as long as it answers.
        let fresh = now.timeIntervalSince(seen) < 60
        let reached = status.isOnline
            ? arrival.addingTimeInterval(Handover.onlineGrace) <= now
            : stop.passed || arrival <= now && !(fresh && Handover.isStillApproaching(plan: plan, status: status))
        guard reached else { return nil }
        return Arrival(stop: stop.name, delayMinutes: minutes(from: planned, to: arrival), refund: refund,
                       observed: seen >= arrival || !status.isOnline && stop.passed,
                       key: String(Int(planned.timeIntervalSince1970 / 60)))
    }

    /// The country a stop ID points to, as a lowercase ISO code: station numbers start with the railways' country
    /// code ("8000261"), SNCF's codes with the ISO one ("FRPLY"), and Transitous names it in the ID
    /// ("3-de-DELFI_de:09162:100").
    static func country(ofStopID id: String) -> String? {
        // Transitous: the stop's place in the trip, then the feed, then the feed's own ID.
        var rest = Substring(id)
        if let dash = rest.firstIndex(of: "-"), rest[..<dash].allSatisfy(\.isNumber), dash != rest.startIndex {
            rest = rest[rest.index(after: dash)...]
        }
        var feed: Substring?
        if let underscore = rest.firstIndex(of: "_"), !rest[..<underscore].allSatisfy(\.isNumber) {
            feed = rest[..<underscore]
            rest = rest[rest.index(after: underscore)...]
        }
        let first = rest.prefix { $0 != "_" && $0 != ":" }
        if first.count == 7, first.allSatisfy(\.isNumber) { return railwayCountries[String(first.prefix(2))] }
        if feed != nil, first.count == 2, rest.dropFirst(2).first == ":", isCode(first) { return first.lowercased() }
        if feed == nil, first.count == 5, first == rest, first.allSatisfy({ $0.isUppercase }), isCode(first.prefix(2)) {
            return first.prefix(2).lowercased()
        }
        // A feed with IDs of its own is a national one.
        if let feed, feed.dropFirst(2).first == "-", isCode(feed.prefix(2)) { return feed.prefix(2).lowercased() }
        return nil
    }

    private static func isCode(_ text: Substring) -> Bool {
        text.count == 2 && text.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static let euCountries: Set<String> = [
        "at", "be", "bg", "hr", "cy", "cz", "dk", "ee", "fi", "fr", "de", "gr", "hu", "ie", "it", "lv", "lt", "lu",
        "mt", "nl", "pl", "pt", "ro", "sk", "si", "es", "se",
    ]

    /// UIC country codes, the first two digits of a station number.
    private static let railwayCountries = [
        "10": "fi", "24": "lt", "25": "lv", "26": "ee", "51": "pl", "52": "bg", "53": "ro", "54": "cz", "55": "hu",
        "56": "sk", "60": "ie", "70": "gb", "71": "es", "73": "gr", "74": "se", "76": "no", "78": "hr", "79": "si",
        "80": "de", "81": "at", "82": "lu", "83": "it", "84": "nl", "85": "ch", "86": "dk", "87": "fr", "88": "be",
        "94": "pt",
    ]
}

extension Trip {
    /// The refund this trip's delay may be worth, when it ended in the EU. Trips logged before that was noted
    /// have none.
    public var refund: PassengerRights.Refund? {
        passengerRights == true ? PassengerRights.refund(delayMinutes: arrivalDelay) : nil
    }
}
