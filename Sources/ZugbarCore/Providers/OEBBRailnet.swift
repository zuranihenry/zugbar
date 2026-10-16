import Foundation

/// ÖBB on-board portal (OEBB hotspot on Railjets and Nightjets).
public struct OEBBRailnet: TrainProvider {
    public let name = "ÖBB"

    let loader: DataLoader

    public init(loader: @escaping DataLoader = URLSession.portal.loader) {
        self.loader = loader
    }

    /// The portal moved its data in 2025; older Railjets may still serve the first path.
    static let paths = ["assets/media/fis/combined.json", "assets/modules/fis/combined.json"]

    public func fetch() async throws -> TrainStatus {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var lastError: Error = ProviderError.missingResource("combined.json")
        for path in Self.paths {
            do {
                let url = URL(string: "https://railnet.oebb.at/\(path)?_time=\(stamp)")!
                return try Self.parse(combined: await loader(url), now: Date())
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Times come as "HH:mm" without a date, so `now` (or the portal's own clock) anchors them. Reads the current
    /// format (`stations`, `latestStatus`) and the one from before 2023 (`stationList`, `currentStation`).
    public static func parse(combined data: Data, now: Date) throws -> TrainStatus {
        let json = try JSONDecoder().decode(CombinedDTO.self, from: data)
        let anchor = json.latestStatus?.dateTime.flatMap { try? Date($0, strategy: .iso8601) } ?? now
        let clock = Clock(now: anchor)

        let stations: [(id: String, name: String?, track: String?, arrival: Times?, departure: Times?)]
        if let current = json.stations {
            stations = current.map { ($0.id, $0.name?.text, $0.track?.text, $0.arrival, $0.departure) }
        } else if let old = json.stationList {
            stations = old.map {
                ($0.id, $0.name?.text, $0.track?.text,
                 Times(scheduled: $0.arrivalSchedule, forecast: $0.arrivalForecast),
                 Times(scheduled: $0.departureSchedule, forecast: $0.departureForecast))
            }
        } else {
            throw ProviderError.missingResource("stations")
        }

        let nextID = json.nextStation?.id ?? json.latestStatus?.situation?.station ?? json.currentStation?.id
        let nextIndex = stations.firstIndex { $0.id == nextID }
        // Arrival and departure of every stop in order, planned and expected apart, so a night train's later stops
        // land on the next day and a late train's forecasts don't.
        let start = (nextIndex ?? 0) * 2
        let planned = clock.dates(stations.flatMap { [$0.arrival?.scheduled, $0.departure?.scheduled] }, anchor: start)
        let expected = clock.dates(stations.flatMap { [$0.arrival?.forecast ?? $0.arrival?.scheduled,
                                                       $0.departure?.forecast ?? $0.departure?.scheduled] }, anchor: start)

        let stops = stations.enumerated().map { index, station in
            Stop(
                id: station.id,
                name: station.name ?? "?",
                scheduledArrival: planned[index * 2],
                expectedArrival: expected[index * 2],
                scheduledDeparture: planned[index * 2 + 1],
                expectedDeparture: expected[index * 2 + 1],
                track: station.track,
                passed: nextIndex.map { index < $0 } ?? false
            )
        }

        let journey = json.currentJourney
        let trainName = [json.trainType ?? journey?.trainType, json.tripNumber ?? json.lineNumber ?? journey?.tripNumber ?? journey?.lineNumber]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " ")
        let speed = json.latestStatus?.speed ?? json.operationalMessagesInfo?.speed.flatMap(Double.init)
        let gps = json.latestStatus?.gpsPosition
        let latitude = (gps?.latitude ?? json.mapInfo?.latitude).flatMap(Double.init)
        let longitude = (gps?.longitude ?? json.mapInfo?.longitude).flatMap(Double.init)

        return TrainStatus(
            provider: "ÖBB",
            trainName: trainName.nilIfEmpty,
            destination: (json.destination ?? journey?.destination)?.text ?? stops.last?.name,
            speed: speed.flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded()) : nil },
            stops: stops,
            nextStopID: nextID,
            portal: .portal("ÖBB Railnet", "https://railnet.oebb.at"),
            position: Coordinate(latitude, longitude)
        )
    }

    /// Resolves "HH:mm" (Vienna time) to the closest matching date, so trips across midnight work.
    struct Clock {
        let now: Date
        var calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
            return calendar
        }()

        func date(_ text: String?) -> Date? {
            guard let text, case let parts = text.split(separator: ":"), parts.count >= 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2)),
                  let sameDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            else { return nil }
            let offset = sameDay.timeIntervalSince(now)
            if offset < -12 * 3600 { return calendar.date(byAdding: .day, value: 1, to: sameDay) }
            if offset > 12 * 3600 { return calendar.date(byAdding: .day, value: -1, to: sameDay) }
            return sameDay
        }

        /// Times in trip order, each within 12 hours of now at `anchor` and then kept in order from there: a time
        /// more than an hour before the one before it is on the next day, so a train longer than 12 hours works.
        func dates(_ texts: [String?], anchor: Int) -> [Date?] {
            var result = texts.map(date)
            let start = min(max(anchor, 0), max(result.count - 1, 0))
            // The first known time from the anchor on, going forward, then going back.
            var previous = result[start...].lazy.compactMap { $0 }.first
            for index in result.indices where index > start {
                guard var date = result[index] else { continue }
                while let previous, date < previous.addingTimeInterval(-3600) { date = calendar.date(byAdding: .day, value: 1, to: date)! }
                result[index] = date
                previous = date
            }
            var next = result[start...].lazy.compactMap { $0 }.first
            for index in result.indices.reversed() where index < start {
                guard var date = result[index] else { continue }
                while let next, date > next.addingTimeInterval(3600) { date = calendar.date(byAdding: .day, value: -1, to: date)! }
                result[index] = date
                next = date
            }
            return result
        }
    }

    struct CombinedDTO: Decodable {
        // Current format.
        let trainType: String?
        let tripNumber: String?
        let lineNumber: String?
        let destination: Localized?
        let nextStation: IDOnly?
        let latestStatus: Latest?
        let stations: [NewStation]?
        // Before 2023.
        let operationalMessagesInfo: OperationalInfo?
        let mapInfo: MapInfo?
        let currentJourney: Journey?
        let currentStation: IDOnly?
        let stationList: [Station]?
    }

    struct IDOnly: Decodable {
        let id: String?
    }

    struct Latest: Decodable {
        let dateTime: String?
        /// km/h
        let speed: Double?
        let gpsPosition: MapInfo?
        let situation: Situation?

        struct Situation: Decodable {
            let station: String?
        }
    }

    struct NewStation: Decodable {
        let id: String
        let name: Localized?
        let track: Localized?
        let arrival: Times?
        let departure: Times?
    }

    struct Times: Decodable {
        let scheduled: String?
        let forecast: String?
    }

    struct MapInfo: Decodable {
        let latitude: String?
        let longitude: String?
    }

    struct OperationalInfo: Decodable {
        let speed: String?
    }

    struct Journey: Decodable {
        let trainType: String?
        let tripNumber: String?
        let lineNumber: String?
        let destination: Localized?
    }

    struct Station: Decodable {
        let id: String
        let name: Localized?
        let track: Localized?
        let arrivalSchedule: String?
        let arrivalForecast: String?
        let departureSchedule: String?
        let departureForecast: String?
    }

    struct Localized: Decodable {
        let all: String?
        let de: String?

        var text: String? { (de ?? all)?.nilIfEmpty }
    }
}
