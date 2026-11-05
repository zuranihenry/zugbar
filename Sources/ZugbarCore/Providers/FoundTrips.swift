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

/// The track of each trip followed, shared like `FoundTrips`. Its shape is nearly all of a trip's data, some 40 of
/// 45 KB compressed for an ICE, so it's fetched once and every update after that, every 30 seconds, goes without:
/// on a regional train's Wi-Fi with a 100 MB limit that's the difference between 5 MB an hour and a quarter of one.
actor TripRoutes {
    /// A trip without a shape is remembered too, as `nil`.
    private var routes: [String: Route?] = [:]
    private var order: [String] = []
    /// A ride with a connection or two, and some looking around.
    static let capacity = 8

    /// `.some(nil)`: fetched before, the trip has no shape.
    func lookup(_ tripID: String) -> Route?? { routes[tripID] }

    func store(_ route: Route?, for tripID: String) {
        if routes.updateValue(route, forKey: tripID) == nil { order.append(tripID) }
        while order.count > Self.capacity { routes[order.removeFirst()] = nil }
    }
}
