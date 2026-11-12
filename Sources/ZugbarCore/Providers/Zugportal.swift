import Foundation

/// DB Regio's on-board portal (WIFI@DB on regional trains; "Zugportal", renamed "Regio Guide"). Endpoint and fields
/// per felix-zenk/onboardapis and KDE's KPublicTransport. Not yet tried on a real train.
///
/// The portal has the trip but neither speed nor position; those come from the train's Icomera router, where it has one.
public struct Zugportal: TrainProvider {
    public let name = "DB Regio"

    /// The old host only redirects to the new one, which `URLSession.portal` doesn't follow; it's tried in case a
    /// train still serves it.
    static let hosts = ["regio-guide.de", "zugportal.de"]
    static let path = "/@prd/zupo-travel-information/api/public/ri/journey"
    static let shared = PortalMemory()

    let loader: DataLoader
    let router: Icomera
    let memory: PortalMemory

    public init(loader: @escaping DataLoader = URLSession.portal.jsonLoader, router: @escaping DataLoader = URLSession.portal.loader) {
        self.init(loader: loader, router: router, memory: Self.shared)
    }

    init(loader: @escaping DataLoader, router: @escaping DataLoader, memory: PortalMemory) {
        self.loader = loader
        self.router = Icomera(loader: router)
        self.memory = memory
    }

    public func fetch() async throws -> TrainStatus {
        try await fetch(now: Date())
    }

    /// The portal's site is on the internet too, so asking costs data on every network, also on a regional train
    /// with a data limit and no portal. Whatever comes back that isn't a trip, the portal is then left alone, for
    /// longer each time, until another network is joined. On board the trip is asked for twice a minute; only the
    /// router, which is on the train, on every poll.
    func fetch(now: Date) async throws -> TrainStatus {
        guard !memory.isPaused(at: now) else { throw ProviderError.missingResource("journey") }
        // Both hosts at once until one has answered, so a network that's stuck doesn't take twice as long.
        let hosts = memory["host"].map { [$0] } ?? Self.hosts
        let found = await withTaskGroup(of: (host: String, status: TrainStatus)?.self) { group in
            for host in hosts {
                group.addTask {
                    let url = URL(string: "https://\(host)\(Self.path)")!
                    guard let journey = try? await memory.load(url, maxAge: 30, now: now, loader: loader),
                          let status = try? Self.parse(journey: journey)
                    else { return nil }
                    return (host, status)
                }
            }
            for await result in group {
                guard let result else { continue }
                group.cancelAll()
                return result as (host: String, status: TrainStatus)?
            }
            return nil
        }
        // Another portal answered first and ended this probe: that says nothing about this one.
        try Task.checkCancellation()
        guard let found else {
            memory["host"] = nil
            memory.failed(at: now)
            throw ProviderError.missingResource("journey")
        }
        memory["host"] = found.host
        memory.succeeded(at: now)
        return Self.adding(await fix(now: now), to: found.status)
    }

    /// A train without an Icomera router is asked again once a minute, not on every poll.
    private func fix(now: Date) async -> Icomera.Fix? {
        guard !memory.isPaused("router", at: now) else { return nil }
        do {
            return try await router.fetch()
        } catch ProviderError.missingResource {
            return nil
        } catch {
            memory.pause("router", until: now.addingTimeInterval(60))
            return nil
        }
    }

    public static func parse(journey data: Data, fix: Icomera.Fix? = nil) throws -> TrainStatus {
        let journey = try JSONDecoder().decode(Journey.self, from: data)
        let listed = (journey.stops?.value ?? []).compactMap(\.value).filter { $0.station?.value?.name?.value != nil }
        guard !listed.isEmpty else { throw ProviderError.missingResource("stops") }

        // "REAL" marks a time that has happened: every stop up to the last one left is behind the train, and so is
        // every stop before one it has arrived at.
        let left = listed.lastIndex { $0.departureTime?.value?.timeType?.value == "REAL" }.map { $0 + 1 } ?? 0
        let reached = listed.lastIndex { $0.arrivalTime?.value?.timeType?.value == "REAL" } ?? 0
        let behind = max(left, reached)

        let stops = listed.enumerated().map { index, stop in
            let station = stop.station?.value, track = stop.track?.value
            return Stop(
                id: station?.evaNo?.value ?? station?.name?.value ?? "",
                name: station?.name?.value ?? "",
                scheduledArrival: stop.arrivalTime?.value?.scheduled,
                expectedArrival: stop.arrivalTime?.value?.expected,
                scheduledDeparture: stop.departureTime?.value?.scheduled,
                expectedDeparture: stop.departureTime?.value?.expected,
                track: track?.prediction?.value ?? track?.target?.value,
                scheduledTrack: track?.target?.value,
                passed: index < behind,
                delayReasons: (stop.messages?.value ?? []).compactMap(\.value).filter { $0.type?.value == "CUSTOMER_REASON" }
                    .compactMap { $0.textShort?.value ?? $0.text?.value },
                coordinate: Coordinate(station?.position?.value?.latitude?.value, station?.position?.value?.longitude?.value),
                cancelled: stop.canceled?.value == true || stop.status?.value == "Canceled"
            )
        }

        // "RE 80 (4711)": the line, which is what the train is called, and the number that tells it apart.
        let number = journey.no?.value.flatMap { $0.isFinite && (1..<1e9).contains($0) ? String(Int($0)) : nil }
        let line = journey.name?.value ?? journey.category?.value
        let trainName = switch (line, number) {
        case (let line?, let number?): line.hasSuffix(number) ? line : "\(line) (\(number))"
        case (let line?, nil): line
        default: nil as String?
        }

        return adding(fix, to: TrainStatus(
            provider: "DB Regio",
            trainName: trainName,
            destination: stops.last { !$0.cancelled }?.name,
            stops: stops,
            nextStopID: stops.first { !$0.passed && !$0.cancelled }?.id,
            portal: .portal("Regio Guide", "https://regio-guide.de")
        ))
    }

    /// A fix the router has had for a while says where the train was.
    static func adding(_ fix: Icomera.Fix?, to status: TrainStatus) -> TrainStatus {
        guard let fix, fix.age < 30 else { return status }
        var status = status
        status.speed = fix.speed
        status.position = fix.coordinate
        return status
    }

    struct Journey: Decodable {
        /// e.g. "RE 80"
        let name: LenientString?
        let category: LenientString?
        /// The train number.
        let no: OEBBRailnet.LenientDouble?
        let stops: Lossy<[Lossy<Stop>]>?

        struct Stop: Decodable {
            let status: LenientString?
            let canceled: LenientBool?
            let station: Lossy<Station>?
            let track: Lossy<Track>?
            let arrivalTime: Lossy<Time>?
            let departureTime: Lossy<Time>?
            let messages: Lossy<[Lossy<Message>]>?
        }

        struct Station: Decodable {
            let evaNo: LenientString?
            let name: LenientString?
            let position: Lossy<Position>?
        }

        struct Position: Decodable {
            let latitude: OEBBRailnet.LenientDouble?
            let longitude: OEBBRailnet.LenientDouble?
        }

        struct Track: Decodable {
            let target: LenientString?
            let prediction: LenientString?
        }

        struct Time: Decodable {
            /// ISO 8601, with an offset or in UTC with milliseconds, depending on the train.
            let target: LenientString?
            let predicted: LenientString?
            let targetTimeInMs: OEBBRailnet.LenientDouble?
            let predictedTimeInMs: OEBBRailnet.LenientDouble?
            /// "SCHEDULE": timetable only, "PREVIEW": forecast, "REAL": happened.
            let timeType: LenientString?

            var scheduled: Date? { date(targetTimeInMs?.value, target?.value) }
            /// Nothing for a time that's only the timetable's again.
            var expected: Date? { timeType?.value == "SCHEDULE" ? nil : date(predictedTimeInMs?.value, predicted?.value) }

            private func date(_ milliseconds: Double?, _ text: String?) -> Date? {
                if let milliseconds, milliseconds.isFinite, milliseconds > 0 { return Date(timeIntervalSince1970: milliseconds / 1000) }
                return text.flatMap(Date.init(portal:))
            }
        }

        struct Message: Decodable {
            let type: LenientString?
            let text: LenientString?
            let textShort: LenientString?
        }
    }
}
