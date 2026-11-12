import Foundation

/// České dráhy's on-board portal (CDWiFi, e.g. on Railjets and ComfortJets). Endpoints and fields per
/// felix-zenk/onboardapis, derhuerst/cd-wifi-client and KDE's KPublicTransport. Not yet tried on a real train.
///
/// The portal only has the timetable: no expected times, tracks or cancellations. Its one delay figure comes
/// without a unit anyone has pinned down, so it's left out.
public struct CDWiFi: TrainProvider {
    public let name = "ČD"

    /// The portal has no HTTPS; the app's Info.plist allows plain HTTP for this host alone. Off the train the name
    /// doesn't resolve, so looking for it costs no data.
    static let tripURL = URL(string: "http://cdwifi.cz/portal/api/timetable/connexion/current")!
    static let realtimeURL = URL(string: "http://cdwifi.cz/portal/api/vehicle/realtime")!

    let loader: DataLoader
    let memory = PortalMemory()

    public init(loader: @escaping DataLoader = URLSession.portal.loader) {
        self.loader = loader
    }

    public func fetch() async throws -> TrainStatus {
        try await fetch(now: Date())
    }

    /// The timetable, with a weather forecast for every stop in it, is asked for once a minute; the position as
    /// often as the portal renews it, every ten seconds.
    func fetch(now: Date) async throws -> TrainStatus {
        let trip = try await memory.load(Self.tripURL, maxAge: 60, now: now, loader: loader)
        let realtime = try? await memory.load(Self.realtimeURL, maxAge: 9, now: now, loader: loader)
        return try Self.parse(trip: trip, realtime: realtime)
    }

    public static func parse(trip tripData: Data, realtime realtimeData: Data?) throws -> TrainStatus {
        let decoder = JSONDecoder()
        let trip = try decoder.decode(Trip.self, from: tripData)
        let realtime = realtimeData.flatMap { try? decoder.decode(Realtime.self, from: $0) }
        let listed = (trip.connexionTimes ?? []).filter { $0.station?.name?.nilIfEmpty != nil }
        guard !listed.isEmpty else { throw ProviderError.missingResource("stops") }

        // State 4 is a stop the train has been to; the ones before the last of them are behind it too.
        let behind = listed.lastIndex { $0.state == 4 }.map { $0 + 1 } ?? 0
        let stops = listed.enumerated().map { index, time in
            Stop(
                id: time.station?.id?.text ?? time.station?.name ?? "",
                name: time.station?.name ?? "",
                scheduledArrival: time.timeArrival.flatMap(Date.init(portal:)),
                scheduledDeparture: time.timeDeparture.flatMap(Date.init(portal:)),
                passed: index < behind,
                coordinate: Coordinate(time.station?.gpsLat?.value, time.station?.gpsLng?.value)
            )
        }

        // Without a fix the portal has no flag to say so, only empty or zero coordinates; the speed then isn't one.
        let position = Coordinate(realtime?.gpsLat?.value, realtime?.gpsLng?.value)
        let speed = realtime?.speed?.value.flatMap { $0.isFinite && (0...500).contains($0) ? Int($0.rounded()) : nil }

        return TrainStatus(
            provider: "ČD",
            trainName: trip.name.flatMap(trainName),
            destination: stops.last?.name,
            speed: position == nil ? nil : speed,
            stops: stops,
            nextStopID: stops.first { !$0.passed }?.id,
            portal: .portal("ČD Wi-Fi", "http://cdwifi.cz"),
            position: position
        )
    }

    /// "RJ 256" from "RJ 256 Example": the portal adds the train's own name, which no timetable search knows.
    static func trainName(_ name: String) -> String? {
        let words = name.split(separator: " ")
        if words.count > 2, words[0].allSatisfy(\.isLetter), words[1].allSatisfy(\.isNumber) {
            return "\(words[0]) \(words[1])"
        }
        return words.joined(separator: " ").nilIfEmpty
    }

    struct Trip: Decodable {
        let name: String?
        let connexionTimes: [Time]?

        struct Time: Decodable {
            /// Local time with an offset, written "+01:00" or "+0100" depending on the portal's version.
            let timeArrival: String?
            let timeDeparture: String?
            let state: Int?
            let station: Station?
        }

        struct Station: Decodable {
            let id: ID?
            let name: String?
            let gpsLat: OEBBRailnet.LenientDouble?
            let gpsLng: OEBBRailnet.LenientDouble?
        }

        /// A number in every answer seen so far.
        struct ID: Decodable {
            let text: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                text = (try? container.decode(Int.self)).map(String.init) ?? (try? container.decode(String.self))?.nilIfEmpty
            }
        }
    }

    struct Realtime: Decodable {
        let gpsLat: OEBBRailnet.LenientDouble?
        let gpsLng: OEBBRailnet.LenientDouble?
        /// km/h
        let speed: OEBBRailnet.LenientDouble?
    }
}
