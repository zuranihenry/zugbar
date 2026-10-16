import Foundation

/// Trips found by name, shared by every lookup in the app: a name search downloads a map of the moving trains.
/// Remembers a hit until the trip ends, and a miss for a while, doubling up to an hour, since the search already
/// looks 90 minutes ahead.
actor FoundTrips {
    enum Answer: Equatable {
        case found(String)
        case notRunning
    }

    private var entries: [String: (tripID: String?, until: Date, misses: Int)] = [:]

    func lookup(_ query: String, at now: Date) -> Answer? {
        guard let entry = entries[Transitous.normalize(query)], now < entry.until else { return nil }
        return entry.tripID.map(Answer.found) ?? .notRunning
    }

    func store(_ query: String, tripID: String, until: Date) {
        entries[Transitous.normalize(query)] = (tripID, until, 0)
    }

    func notRunning(_ query: String, at now: Date) {
        let key = Transitous.normalize(query)
        let misses = (entries[key]?.tripID == nil ? entries[key]?.misses ?? 0 : 0) + 1
        entries[key] = (nil, now.addingTimeInterval(min(5 * 60 * pow(2, Double(misses - 1)), 60 * 60)), misses)
    }

    /// The found trip is over; a later one of the same name may run, so search again next time.
    func ended(_ query: String, at now: Date) {
        entries[Transitous.normalize(query)] = nil
    }
}
