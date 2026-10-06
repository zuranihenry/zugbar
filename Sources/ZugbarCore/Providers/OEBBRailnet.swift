import Foundation

/// ÖBB on-board portal (OEBB hotspot on Railjets and Nightjets).
public struct OEBBRailnet: TrainProvider {
    public let name = "ÖBB"

    let loader: DataLoader

    public init(loader: @escaping DataLoader = URLSession.portal.loader) {
        self.loader = loader
    }

    public func fetch() async throws -> TrainStatus {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "https://railnet.oebb.at/assets/modules/fis/combined.json?_time=\(stamp)")!
        return try Self.parse(combined: await loader(url), now: Date())
    }

    /// Times come as "HH:mm" without a date, so `now` anchors them.
    public static func parse(combined data: Data, now: Date) throws -> TrainStatus {
        let json = try JSONDecoder().decode(CombinedDTO.self, from: data)
        let clock = Clock(now: now)

        let currentID = json.currentStation?.id
        let currentIndex = json.stationList.firstIndex { $0.id == currentID }

        let stops = json.stationList.enumerated().map { index, station in
            Stop(
                id: station.id,
                name: station.name.all,
                scheduledArrival: clock.date(station.arrivalSchedule),
                expectedArrival: clock.date(station.arrivalForecast) ?? clock.date(station.arrivalSchedule),
                scheduledDeparture: clock.date(station.departureSchedule),
                expectedDeparture: clock.date(station.departureForecast) ?? clock.date(station.departureSchedule),
                track: station.track?.all.nilIfEmpty,
                passed: currentIndex.map { index < $0 } ?? false
            )
        }

        let journey = json.currentJourney
        let trainName = [journey?.trainType, journey?.tripNumber ?? journey?.lineNumber]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " ")

        return TrainStatus(
            provider: "ÖBB",
            trainName: trainName.nilIfEmpty,
            destination: journey?.destination?.all.nilIfEmpty ?? stops.last?.name,
            speed: json.operationalMessagesInfo?.speed.flatMap { Int($0) },
            stops: stops,
            nextStopID: currentID,
            portal: .portal("ÖBB Railnet", "https://railnet.oebb.at"),
            position: Coordinate(json.mapInfo?.latitude.flatMap(Double.init), json.mapInfo?.longitude.flatMap(Double.init))
        )
    }

    /// Resolves "HH:mm" (CET) to the closest matching date, so trips across midnight work.
    struct Clock {
        let now: Date
        var calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
            return calendar
        }()

        func date(_ text: String?) -> Date? {
            guard let text, case let parts = text.split(separator: ":"), parts.count == 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1]),
                  let sameDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)
            else { return nil }
            let offset = sameDay.timeIntervalSince(now)
            if offset < -12 * 3600 { return calendar.date(byAdding: .day, value: 1, to: sameDay) }
            if offset > 12 * 3600 { return calendar.date(byAdding: .day, value: -1, to: sameDay) }
            return sameDay
        }
    }

    struct CombinedDTO: Decodable {
        let operationalMessagesInfo: OperationalInfo?
        let mapInfo: MapInfo?
        let currentJourney: Journey?
        let currentStation: Station?
        let stationList: [Station]
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
        let name: Localized
        let track: Localized?
        let arrivalSchedule: String?
        let arrivalForecast: String?
        let departureSchedule: String?
        let departureForecast: String?
    }

    struct Localized: Decodable {
        let all: String
    }
}
