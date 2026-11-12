import Foundation

/// České dráhy's on-board portal (CDWiFi, e.g. on Railjets and ComfortJets). Endpoints and fields per
/// felix-zenk/onboardapis, derhuerst/cd-wifi-client and KDE's KPublicTransport. Not yet tried on a real train.
///
/// The portal only has the timetable: no expected times, tracks or cancellations. Its one delay figure comes
/// without a unit anyone has pinned down, so it's left out.
public struct CDWiFi: TrainProvider {
    public let name = "ČD"

    /// The portal has no HTTPS; the app's Info.plist allows plain HTTP for this host alone.
    static let tripURL = URL(string: "http://cdwifi.cz/portal/api/timetable/connexion/current")!
    static let realtimeURL = URL(string: "http://cdwifi.cz/portal/api/vehicle/realtime")!
    static let shared = PortalMemory()

    let loader: DataLoader
    let memory: PortalMemory

    public init(loader: @escaping DataLoader = URLSession.portal.jsonLoader) {
        self.init(loader: loader, memory: Self.shared)
    }

    init(loader: @escaping DataLoader, memory: PortalMemory) {
        self.loader = loader
        self.memory = memory
    }

    public func fetch() async throws -> TrainStatus {
        try await fetch(now: Date())
    }

    /// The timetable, with a weather forecast for every stop in it, is asked for once a minute; the position as
    /// often as the portal renews it, every ten seconds. Without a trip in the answer the portal is left alone,
    /// for longer each time, until another network is joined.
    func fetch(now: Date) async throws -> TrainStatus {
        guard !memory.isPaused(at: now) else { throw ProviderError.missingResource("trip") }
        do {
            let trip = try await memory.load(Self.tripURL, maxAge: 60, now: now, loader: loader)
            let realtime = try? await memory.load(Self.realtimeURL, maxAge: 9, now: now, loader: loader)
            let status = try Self.parse(trip: trip, realtime: realtime)
            memory.succeeded(at: now)
            return status
        } catch {
            // Another portal answered first and ended this probe: that says nothing about this one.
            if !Task.isCancelled { memory.failed(at: now) }
            throw error
        }
    }

    public static func parse(trip tripData: Data, realtime realtimeData: Data?) throws -> TrainStatus {
        let decoder = JSONDecoder()
        let trip = try decoder.decode(Trip.self, from: tripData)
        let realtime = realtimeData.flatMap { try? decoder.decode(Realtime.self, from: $0) }
        let listed = (trip.connexionTimes?.value ?? []).compactMap(\.value).filter { $0.station?.value?.name?.value != nil }
        guard !listed.isEmpty else { throw ProviderError.missingResource("stops") }

        // State 4 is a stop the train has been to; the ones before the last of them are behind it too.
        let behind = listed.lastIndex { $0.state?.value == 4 }.map { $0 + 1 } ?? 0
        let stops = listed.enumerated().map { index, time in
            let station = time.station?.value
            return Stop(
                id: station?.id?.value ?? station?.name?.value ?? "",
                name: station?.name?.value ?? "",
                scheduledArrival: time.timeArrival?.value.flatMap(Date.init(portal:)),
                scheduledDeparture: time.timeDeparture?.value.flatMap(Date.init(portal:)),
                passed: index < behind,
                coordinate: Coordinate(station?.gpsLat?.value, station?.gpsLng?.value)
            )
        }

        // Without a fix the portal has no flag to say so, only empty or zero coordinates; the speed then isn't one.
        let position = Coordinate(realtime?.gpsLat?.value, realtime?.gpsLng?.value)
        let speed = realtime?.speed?.value.flatMap { $0.isFinite && (0...500).contains($0) ? Int($0.rounded()) : nil }

        return TrainStatus(
            provider: "ČD",
            trainName: trip.name?.value.flatMap(trainName),
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
        let name: LenientString?
        let connexionTimes: Lossy<[Lossy<Time>]>?

        struct Time: Decodable {
            /// Local time with an offset, written "+01:00" or "+0100" depending on the portal's version.
            let timeArrival: LenientString?
            let timeDeparture: LenientString?
            let state: OEBBRailnet.LenientDouble?
            let station: Lossy<Station>?
        }

        struct Station: Decodable {
            /// A number in every answer seen so far.
            let id: LenientString?
            let name: LenientString?
            let gpsLat: OEBBRailnet.LenientDouble?
            let gpsLng: OEBBRailnet.LenientDouble?
        }
    }

    struct Realtime: Decodable {
        let gpsLat: OEBBRailnet.LenientDouble?
        let gpsLng: OEBBRailnet.LenientDouble?
        /// km/h
        let speed: OEBBRailnet.LenientDouble?
    }
}
