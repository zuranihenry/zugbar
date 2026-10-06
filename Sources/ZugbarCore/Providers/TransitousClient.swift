import Foundation

/// Station search and departure boards, used to pick regional trains (S, RB, RE).
public struct TransitousClient: Sendable {
    let loader: DataLoader

    public init(loader: @escaping DataLoader = URLSession.transitous.loader) {
        self.loader = loader
    }

    public struct Station: Sendable, Equatable, Identifiable, Decodable {
        public let id: String
        public var name: String
        let modes: [String]?

        public init(id: String, name: String) {
            self.id = id
            self.name = name
            self.modes = nil
        }
    }

    public struct Departure: Sendable, Equatable, Identifiable {
        public var id: String { tripID }
        public let tripID: String
        /// e.g. "RE6 (89736)", "S19", "ICE 591"
        public let displayName: String
        public let line: String
        public let headsign: String?
        public let scheduled: Date?
        public let expected: Date?
        public let track: String?
        public let cancelled: Bool
        public let realTime: Bool
        /// S-Bahn and regional trains, as opposed to long-distance and night trains.
        public let isRegional: Bool

        public init(
            tripID: String, displayName: String, line: String, headsign: String?,
            scheduled: Date?, expected: Date?, track: String?, cancelled: Bool, realTime: Bool, isRegional: Bool = true
        ) {
            self.tripID = tripID
            self.displayName = displayName
            self.line = line
            self.headsign = headsign
            self.scheduled = scheduled
            self.expected = expected
            self.track = track
            self.cancelled = cancelled
            self.realTime = realTime
            self.isRegional = isRegional
        }

        public var time: Date? { expected ?? scheduled }

        public var delayMinutes: Int? {
            guard let scheduled, let expected else { return nil }
            return minutes(from: scheduled, to: expected)
        }
    }

    static let regionalModes: Set<String> = ["REGIONAL_FAST_RAIL", "REGIONAL_RAIL", "SUBURBAN"]

    static let railModes: Set<String> = [
        "HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_FAST_RAIL", "REGIONAL_RAIL", "SUBURBAN", "RAIL",
    ]

    public func stations(matching text: String) async throws -> [Station] {
        var url = Transitous.base.appending(path: "v1/geocode")
        url.append(queryItems: [URLQueryItem(name: "text", value: text), URLQueryItem(name: "type", value: "STOP")])
        return try Self.parseStations(await loader(url))
    }

    public func departures(from station: Station, at time: Date = Date(), count: Int = 80) async throws -> [Departure] {
        var url = Transitous.base.appending(path: "v6/stoptimes")
        url.append(queryItems: [
            URLQueryItem(name: "stopId", value: station.id),
            URLQueryItem(name: "time", value: time.formatted(.iso8601)),
            URLQueryItem(name: "n", value: String(count)),
        ])
        return try Self.parseDepartures(await loader(url))
    }

    /// Matches a line ("RE5", "re 5", "S19") or a train number ("26836").
    public static func filter(_ departures: [Departure], line text: String) -> [Departure] {
        let wanted = Transitous.normalize(text)
        guard !wanted.isEmpty else { return departures }
        return departures.filter {
            Transitous.normalize($0.line) == wanted || Transitous.normalize($0.displayName).contains("(\(wanted))")
        }
    }

    static func parseStations(_ data: Data) throws -> [Station] {
        try JSONDecoder().decode([Station].self, from: data)
            .filter { !railModes.isDisjoint(with: $0.modes ?? []) }
            .map { station in
                var station = station
                station.name = StationName.tidy(station.name)
                return station
            }
    }

    static func parseDepartures(_ data: Data) throws -> [Departure] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let departures = try decoder.decode(StopTimes.self, from: data).stopTimes
            .filter { railModes.contains($0.mode) }
            .map { stopTime in
                let name = stopTime.displayName ?? stopTime.routeShortName ?? "?"
                return Departure(
                    tripID: stopTime.tripId,
                    displayName: name,
                    line: lineName(from: name),
                    headsign: stopTime.headsign.map(StationName.tidy),
                    scheduled: stopTime.place.scheduledDeparture,
                    expected: stopTime.place.departure,
                    track: stopTime.place.track ?? stopTime.place.scheduledTrack,
                    cancelled: stopTime.cancelled ?? false,
                    realTime: stopTime.realTime ?? false,
                    isRegional: regionalModes.contains(stopTime.mode)
                )
            }
        return deduplicated(departures)
    }

    /// Overlapping feeds (e.g. DELFI and VBN) list the same train twice; keep one, preferring live data.
    static func deduplicated(_ departures: [Departure]) -> [Departure] {
        var kept: [Departure] = []
        var indexByKey: [String: Int] = [:]
        for departure in departures {
            let key = "\(Transitous.normalize(departure.line))|\(departure.scheduled?.timeIntervalSince1970 ?? 0)"
            if let index = indexByKey[key] {
                if departure.realTime && !kept[index].realTime { kept[index] = departure }
            } else {
                indexByKey[key] = kept.count
                kept.append(departure)
            }
        }
        return kept
    }

    /// Regional lines at a station for picking, S-Bahn first: ["S3", "S4", "RB38", "RE2", "RE70"].
    public static func lines(in departures: [Departure]) -> [String] {
        func rank(_ line: String) -> Int {
            let prefix = line.prefix { $0.isLetter }.uppercased()
            return ["S": 0, "RB": 1, "RE": 2, "IRE": 3].first { $0.key == prefix }?.value ?? 4
        }
        return Array(Set(departures.filter(\.isRegional).map(\.line))).sorted {
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// "RE6 (89736)" → "RE6"
    static func lineName(from displayName: String) -> String {
        displayName.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? displayName
    }

    struct StopTimes: Decodable {
        let stopTimes: [StopTime]
    }

    struct StopTime: Decodable {
        let mode: String
        let tripId: String
        let displayName: String?
        let routeShortName: String?
        let headsign: String?
        let cancelled: Bool?
        let realTime: Bool?
        let place: Transitous.Place
    }
}
