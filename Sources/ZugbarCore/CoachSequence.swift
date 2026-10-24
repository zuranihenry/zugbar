import Foundation

/// The coach the user sits in, and optionally the seat, e.g. coach "8", seat "42".
public struct Seat: Codable, Sendable, Equatable {
    public var coach: String
    public var number: String?

    public init(coach: String, number: String? = nil) {
        self.coach = coach
        self.number = number
    }

    /// From what the user typed; nil without a coach.
    public init?(typedCoach coach: String, seat: String) {
        let coach = coach.trimmingCharacters(in: .whitespaces)
        guard !coach.isEmpty else { return nil }
        self.init(coach: coach, number: seat.trimmingCharacters(in: .whitespaces).nilIfEmpty)
    }
}

/// Where a train's coaches stop along the platform, from DB's coach sequence (Wagenreihung).
public struct CoachSequence: Sendable, Equatable {
    public struct Coach: Sendable, Equatable {
        /// As printed on the coach and the ticket, e.g. "8" or "26".
        public var number: String
        /// The platform sector it stops in, e.g. "C".
        public var sector: String?
        public var closed: Bool

        public init(number: String, sector: String?, closed: Bool = false) {
            self.number = number
            self.sector = sector
            self.closed = closed
        }
    }

    public var track: String?
    /// In order along the platform, from sector A on. Two coupled trains count their coaches apart (21–29, 31–39).
    public var coaches: [Coach]

    public init(track: String?, coaches: [Coach]) {
        self.track = track
        self.coaches = coaches
    }

    /// Coach `number` as the user typed it: "08" is coach 8. Nil when the train runs without it today.
    public func coach(_ number: String) -> Coach? {
        let wanted = Self.normalize(number)
        return coaches.first { Self.normalize($0.number) == wanted }
    }

    /// Long-distance trains, whose coaches are numbered on tickets and reservations.
    public static func numbersCoaches(_ trainName: String?) -> Bool {
        [TrainKind.highSpeed, .intercity].contains(TrainKind.of(trainName))
    }

    private static func normalize(_ number: String) -> String {
        let text = Transitous.normalize(number)
        let digits = text.drop { $0 == "0" }
        return digits.isEmpty ? text : String(digits)
    }
}

/// DB's coach sequences, from the API behind bahn.de's own coach sequence pages. It needs no key but is undocumented,
/// and bahn.de's firewall blocks clients that ask too often: only ask for trains the user entered a coach for, as
/// `CoachSequencePolicy` allows. It knows departures only, so not a train's last stop, and only for today.
public struct CoachSequenceClient: Sendable {
    let loader: DataLoader

    static let base = URL(string: "https://www.bahn.de/web/api/")!

    public init(loader: @escaping DataLoader = URLSession.bahn.loader) {
        self.loader = loader
    }

    /// A train leaving a station: what a coach sequence is asked for.
    public struct Query: Hashable, Sendable {
        /// e.g. "ICE"
        public var category: String
        public var number: String
        /// DB's station number (EVA), e.g. "8000001".
        public var station: String
        /// The planned departure there.
        public var departure: Date

        public init(category: String, number: String, station: String, departure: Date) {
            self.category = category
            self.number = number
            self.station = station
            self.departure = departure
        }

        /// For `trainName` ("ICE 123", "RE80 (4711)") leaving `station`; nil for trains without a number.
        public init?(trainName: String, station: String, departure: Date) {
            guard let (category, number) = TrainStatus(provider: "", trainName: trainName).trainNumber else { return nil }
            self.init(category: category, number: number, station: station, departure: departure)
        }
    }

    /// Nil when DB has no coach sequence for it: regional trains, a train's last stop, another day.
    public func sequence(_ query: Query) async throws -> CoachSequence? {
        do {
            return try Self.parse(await loader(Self.url(for: query)))
        } catch ProviderError.badStatus(404) {
            return nil
        }
    }

    /// Date and time in UTC, like bahn.de asks: "2026-01-01" and "2026-01-01T12:00:00.000Z".
    static func url(for query: Query) -> URL {
        let day = Date.ISO8601FormatStyle().year().month().day()
        var url = base.appending(path: "reisebegleitung/wagenreihung/vehicle-sequence")
        url.appendQuery([
            URLQueryItem(name: "administrationId", value: "80"),
            URLQueryItem(name: "category", value: query.category),
            URLQueryItem(name: "date", value: query.departure.formatted(day)),
            URLQueryItem(name: "evaNumber", value: query.station),
            URLQueryItem(name: "number", value: query.number),
            URLQueryItem(name: "time", value: query.departure.formatted(
                day.time(includingFractionalSeconds: true).timeZone(separator: .omitted)
            )),
        ])
        return url
    }

    static func parse(_ data: Data) throws -> CoachSequence {
        struct Response: Decodable {
            let departurePlatform: String?
            let groups: [Group]
        }
        struct Group: Decodable { let vehicles: [Vehicle] }
        struct Vehicle: Decodable {
            let wagonIdentificationNumber: Number?
            let status: String?
            let platformPosition: Position?
        }
        struct Position: Decodable { let sector: String? }
        /// A number in some answers, a string in others.
        struct Number: Decodable {
            let text: String
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) {
                    text = String(number)
                } else {
                    text = try container.decode(String.self)
                }
            }
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        // Locomotives have no number; they aren't coaches anyone sits in.
        let coaches = response.groups.flatMap(\.vehicles).compactMap { vehicle -> CoachSequence.Coach? in
            guard let number = vehicle.wagonIdentificationNumber?.text.nilIfEmpty else { return nil }
            return CoachSequence.Coach(
                number: number, sector: vehicle.platformPosition?.sector?.nilIfEmpty, closed: vehicle.status == "CLOSED"
            )
        }
        return CoachSequence(track: response.departurePlatform, coaches: coaches)
    }

    /// DB's station number for `stop`: on board an ICE or Railjet it's the stop's ID ("8000001_00"); for trains
    /// followed online it's the DB station nearest the stop. `category` picks a long-distance station where the
    /// stop has one, e.g. not the S-Bahn station underneath.
    public func stationNumber(for stop: Stop, category: String) async throws -> String? {
        if let number = Self.stationNumber(inStopID: stop.id) { return number }
        guard let coordinate = stop.coordinate else { return nil }
        var url = Self.base.appending(path: "reiseloesung/orte/nearby")
        url.appendQuery([
            URLQueryItem(name: "lat", value: String(coordinate.latitude)),
            URLQueryItem(name: "long", value: String(coordinate.longitude)),
            URLQueryItem(name: "radius", value: "1000"),
            URLQueryItem(name: "maxNo", value: "10"),
        ])
        return try Self.parseNearby(await loader(url), category: category)
    }

    static func stationNumber(inStopID id: String) -> String? {
        let number = id.split(separator: "_").first.map(String.init) ?? id
        return number.count == 7 && number.allSatisfy(\.isNumber) ? number : nil
    }

    static func parseNearby(_ data: Data, category: String) throws -> String? {
        struct Place: Decodable {
            let extId: String?
            let type: String?
            let products: [String]?
        }
        let rail: Set = ["ICE", "EC_IC", "IR", "REGIONAL", "SBAHN"]
        let product = switch category.uppercased() {
        case "ICE", "ECE": "ICE"
        case "IC", "EC", "RJ", "RJX", "NJ", "EN", "FLX": "EC_IC"
        case "S": "SBAHN"
        default: "REGIONAL"
        }
        let stations = try JSONDecoder().decode([Place].self, from: data).filter { place in
            place.type == "ST" && place.extId.map { stationNumber(inStopID: $0) != nil } == true
                && !rail.isDisjoint(with: place.products ?? [])
        }
        // Nearest first.
        return (stations.first { $0.products?.contains(product) == true } ?? stations.first)?.extId
    }
}

/// How often to ask bahn.de, whose firewall blocks clients that ask often (seen after a dozen or so requests within
/// minutes): only from two hours before a departure, each train and stop at most every half hour, at least a minute
/// between any two, and nothing for six hours after bahn.de refused one.
public struct CoachSequencePolicy<Key: Hashable>: Sendable where Key: Sendable {
    private var asked: [Key: Date] = [:]
    private var last: Date?
    private var blockedUntil: Date?

    public init() {}

    /// Whether to ask now about the train leaving at `departure`; counts as asked when it says so.
    public mutating func mayAsk(_ key: Key, departure: Date, now: Date) -> Bool {
        guard departure > now.addingTimeInterval(-10 * 60), departure < now.addingTimeInterval(2 * 60 * 60),
              blockedUntil.map({ now >= $0 }) ?? true,
              last.map({ now.timeIntervalSince($0) >= 60 }) ?? true,
              asked[key].map({ now.timeIntervalSince($0) >= 30 * 60 }) ?? true
        else { return false }
        asked = asked.filter { now.timeIntervalSince($0.value) < 6 * 60 * 60 }
        asked[key] = now
        last = now
        return true
    }

    /// After a failed request: a refusal (403, 429) stops all of them for a while.
    public mutating func failed(_ error: Error, now: Date) {
        if case .badStatus(let code) = error as? ProviderError, code == 403 || code == 429 {
            blockedUntil = now.addingTimeInterval(6 * 60 * 60)
        }
    }
}
