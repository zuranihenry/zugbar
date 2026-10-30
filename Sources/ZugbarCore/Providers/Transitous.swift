import Foundation

/// Follows a train online via Transitous (https://transitous.org), either by name or by trip ID.
/// Provides timetable, delays and tracks, but no live speed.
public actor Transitous: TrainProvider {
    public nonisolated let name = "Transitous"
    public nonisolated let label: String

    static let base = URL(string: "https://api.transitous.org/api/")!

    private let query: String?
    private var tripID: String?
    private var betterNames: [String: String] = [:]
    private let loader: DataLoader

    /// Searches running long-distance trains, e.g. "ICE 123", "ice123" or "123".
    public init(query: String, loader: @escaping DataLoader = URLSession.transitous.loader) {
        self.label = query
        self.query = query
        self.loader = loader
    }

    public init(tripID: String, label: String, loader: @escaping DataLoader = URLSession.transitous.loader) {
        self.label = label
        self.query = nil
        self.tripID = tripID
        self.loader = loader
    }

    public enum LookupError: Error, Equatable {
        case notRunning
        case tripEnded
    }

    /// Name searches download a map of the moving trains (megabytes), so what they found is remembered for the
    /// whole app: every new lookup, Reload or network change would otherwise search again.
    static let found = FoundTrips()

    public func fetch() async throws -> TrainStatus {
        let now = Date()
        var searched = false
        if tripID == nil, let query {
            switch await Self.found.lookup(query, at: now) {
            case .found(let id): tripID = id
            case .notRunning: throw LookupError.notRunning
            case nil:
                tripID = try await findTrip(named: query, now: now)
                searched = true
                if tripID == nil { await Self.found.notRunning(query, at: now) }
            }
        }
        guard var tripID else { throw LookupError.notRunning }

        let data: Data
        do {
            data = try await loader(Self.tripURL(tripID))
        } catch ProviderError.badStatus(404) {
            // Just searched: another search now would find the same trip.
            guard let query, !searched else { throw ProviderError.badStatus(404) }
            (tripID, data) = try await searchAgain(query, after: tripID, now: now)
        }
        var status = try Self.parse(trip: data, now: now)
        status.stops = await withCityNames(status.stops)
        // A train cut short may end at one of those stops.
        if let end = Self.cutShortEnd(of: status.stops) { status.destination = end }

        if let end = status.stops.last?.arrival, now > end.addingTimeInterval(15 * 60) {
            if let query { await Self.found.ended(query, at: now) }
            throw LookupError.tripEnded
        }
        if let query { await Self.found.store(query, tripID: tripID, until: (status.stops.last?.arrival ?? now).addingTimeInterval(15 * 60)) }
        return status
    }

    /// Transitous renumbers trips when it reloads a feed, so a trip found by name can vanish under its old ID.
    /// Searches the name once more; when that finds nothing new, waits as for a train that isn't running,
    /// so a dead ID doesn't cost a map download on every update.
    private func searchAgain(_ query: String, after dead: String, now: Date) async throws -> (String, Data) {
        await Self.found.ended(query, at: now)
        tripID = nil
        do {
            guard let found = try await findTrip(named: query, now: now), found != dead else { throw LookupError.notRunning }
            let data = try await loader(Self.tripURL(found))
            tripID = found
            return (found, data)
        } catch LookupError.notRunning, ProviderError.badStatus(404) {
            await Self.found.notRunning(query, at: now)
            throw LookupError.notRunning
        }
    }

    static func tripURL(_ tripID: String) -> URL {
        var url = base.appending(path: "v6/trip")
        url.appendQuery([URLQueryItem(name: "tripId", value: tripID)])
        return url
    }

    /// Replaces names like "Hauptbahnhof (oben)" with the nearest proper station name ("Stuttgart Hbf").
    private func withCityNames(_ stops: [Stop]) async -> [Stop] {
        var result = stops
        for index in result.indices where StationName.lacksCity(result[index].name) {
            guard let coordinate = result[index].coordinate else { continue }
            let key = "\(coordinate.latitude),\(coordinate.longitude)"
            if betterNames[key] == nil {
                var url = Self.base.appending(path: "v1/reverse-geocode")
                url.appendQuery([URLQueryItem(name: "place", value: key), URLQueryItem(name: "type", value: "STOP")])
                do {
                    let names = try JSONDecoder().decode([NamedPlace].self, from: await loader(url)).map(\.name)
                    betterNames[key] = names.map(StationName.tidy).first { !StationName.lacksCity($0) } ?? result[index].name
                } catch where error.isTransientNetwork {
                    // In a tunnel or on weak Wi-Fi: ask again next update rather than keep the bare name all ride.
                } catch {
                    // An answer, just not a usable one: don't ask again on every update.
                    betterNames[key] = result[index].name
                }
            }
            result[index].name = betterNames[key] ?? result[index].name
        }
        return result
    }

    private struct NamedPlace: Decodable { let name: String }

    /// A map area as Transitous expects it: "lat,lon" of the south-west and north-east corners.
    typealias Area = (min: String, max: String)
    /// Germany, Austria, Switzerland and the Benelux, where most trips are followed.
    static let coreArea: Area = ("45.5,2.5", "55.5,17.5")
    /// Europe from Lisbon to Helsinki.
    static let europe: Area = ("35,-10", "62,32")

    /// Where and how far ahead to look, in order. Transitous rejects answers that get too large (422),
    /// so the long look-ahead is limited to the core area, and Europe-wide searches stay short.
    static let searches: [(area: Area, window: TimeInterval)] = [(europe, 60), (coreArea, 90 * 60), (europe, 30 * 60)]

    /// Transitous has no train-number search, so list what's moving and match the name.
    /// At this zoom level the map only includes long-distance trains.
    /// A bare number like "1356" is ambiguous (ICE 1356, or Swedish train 1356), so a match without a
    /// long-distance prefix is only taken once no search finds one with it.
    func findTrip(named query: String, now: Date) async throws -> String? {
        var fallback: String?
        for search in Self.searches {
            let url = Self.mapTripsURL(from: now, to: now.addingTimeInterval(search.window), area: search.area)
            let data: Data
            do {
                data = try await loader(url)
            } catch ProviderError.badStatus(422) {
                continue
            }
            guard let match = try Self.matchTrip(in: data, query: query) else { continue }
            if !match.ambiguous { return match.tripID }
            fallback = fallback ?? match.tripID
        }
        return fallback
    }

    static func mapTripsURL(from start: Date, to end: Date, area: Area = europe) -> URL {
        var url = base.appending(path: "v6/map/trips")
        url.appendQuery([
            URLQueryItem(name: "zoom", value: "6"),
            URLQueryItem(name: "min", value: area.min),
            URLQueryItem(name: "max", value: area.max),
            URLQueryItem(name: "startTime", value: start.formatted(.iso8601)),
            URLQueryItem(name: "endTime", value: end.formatted(.iso8601)),
            URLQueryItem(name: "precision", value: "2"),
        ])
        return url
    }

    struct TripMatch: Equatable {
        let tripID: String
        /// A bare number matched a train without a long-distance prefix; a better match may exist elsewhere.
        let ambiguous: Bool
    }

    static func matchTrip(in data: Data, query: String) throws -> TripMatch? {
        let segments = try JSONDecoder().decode([MapSegment].self, from: data)
        let wanted = normalize(query)
        let numberOnly = wanted.allSatisfy(\.isNumber)
        let longDistance = ["ICE", "IC", "EC", "ECE", "RJ", "RJX", "NJ", "EN", "TGV", "FLX"]

        let candidates = segments
            .filter { $0.mode != "AIRPLANE" && $0.mode != "BUS" && $0.mode != "COACH" }
            .flatMap { segment in segment.trips.map { (trip: $0, realTime: segment.realTime ?? false) } }
            .filter { candidate in
                let name = normalize(candidate.trip.displayName ?? "")
                return numberOnly ? name.drop(while: \.isLetter) == wanted : name == wanted
            }
        // Two feeds can list the same train; the copy with live data is the one worth following.
        let isLongDistance = { (trip: TripRef) in longDistance.contains { normalize(trip.displayName ?? "").hasPrefix($0) } }
        let ranked = candidates.enumerated().sorted { a, b in
            let rank = { (c: (trip: TripRef, realTime: Bool)) in (isLongDistance(c.trip) ? 0 : 2) + (c.realTime ? 0 : 1) }
            return (rank(a.element), a.offset) < (rank(b.element), b.offset)
        }.map(\.element)

        if let best = ranked.first(where: { isLongDistance($0.trip) }) {
            return TripMatch(tripID: best.trip.tripId, ambiguous: false)
        }
        return ranked.first.map { TripMatch(tripID: $0.trip.tripId, ambiguous: numberOnly) }
    }

    public static func normalize(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace }
    }

    static func parse(trip data: Data, now: Date) throws -> TrainStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let itinerary = try decoder.decode(Itinerary.self, from: data)
        guard let leg = itinerary.legs.first(where: { $0.mode != "WALK" }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No train leg"))
        }

        let places = [leg.from] + (leg.intermediateStops ?? []) + [leg.to]
        let tripCancelled = leg.cancelled ?? false
        let stops = places.enumerated().map { index, place in
            Stop(
                // The station rather than its platform: the platform's ID changes when the train changes track.
                id: "\(index)-\(place.parentId ?? place.stopId ?? place.name)",
                name: StationName.tidy(place.name),
                scheduledArrival: place.scheduledArrival,
                expectedArrival: place.arrival,
                scheduledDeparture: place.scheduledDeparture,
                expectedDeparture: place.departure,
                track: place.track ?? place.scheduledTrack,
                scheduledTrack: place.scheduledTrack,
                passed: (place.departure ?? place.arrival).map { $0 <= now } ?? false,
                coordinate: Coordinate(place.lat, place.lon),
                cancelled: tripCancelled || place.cancelled == true
            )
        }

        // No position available, so progress is by time.
        var progress: Double?
        if let start = stops.first?.departure, let end = stops.last?.arrival, end > start {
            progress = min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
        }

        let route = leg.legGeometry.map { Route(points: Route.decode($0.points, precision: $0.precision ?? 5)) }

        return TrainStatus(
            provider: "Transitous",
            trainName: leg.displayName ?? leg.tripShortName,
            // Some trips (e.g. TGVs) come with an empty headsign.
            destination: cutShortEnd(of: stops) ?? StationName.tidy(leg.headsign.flatMap { $0.isEmpty ? nil : $0 } ?? leg.to.name),
            stops: stops,
            nextStopID: stops.first { !$0.passed && !$0.cancelled }?.id,
            progress: progress,
            route: route.flatMap { $0.points.count > 1 ? $0 : nil }
        )
    }

    /// A train cut short keeps its headsign; it now ends at the last stop it still calls at. A trip cancelled
    /// as a whole has no such stop and keeps its destination.
    static func cutShortEnd(of stops: [Stop]) -> String? {
        stops.last?.cancelled == true ? stops.last(where: { !$0.cancelled })?.name : nil
    }

    struct MapSegment: Decodable {
        let mode: String?
        let trips: [TripRef]
        let realTime: Bool?
    }

    struct TripRef: Decodable {
        let tripId: String
        let displayName: String?
    }

    struct Itinerary: Decodable {
        let legs: [Leg]
    }

    struct Leg: Decodable {
        let mode: String
        let headsign: String?
        let displayName: String?
        let tripShortName: String?
        let from: Place
        let to: Place
        let intermediateStops: [Place]?
        let legGeometry: Geometry?
        let cancelled: Bool?
    }

    struct Geometry: Decodable {
        let points: String
        let precision: Int?
    }

    struct Place: Decodable {
        let name: String
        let stopId: String?
        /// The station a platform's `stopId` belongs to; not every feed gives one.
        let parentId: String?
        let arrival: Date?
        let departure: Date?
        let scheduledArrival: Date?
        let scheduledDeparture: Date?
        let track: String?
        let scheduledTrack: String?
        let lat: Double?
        let lon: Double?
        let cancelled: Bool?
    }
}
