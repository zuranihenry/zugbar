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

    public init(loader: @escaping DataLoader = URLSession.portal.loader) {
        self.init(loader: loader, memory: Self.shared)
    }

    init(loader: @escaping DataLoader, memory: PortalMemory) {
        self.loader = loader
        self.router = Icomera(loader: loader)
        self.memory = memory
    }

    /// A new network may be a train: ask again right away.
    public static func joinedNetwork() { shared.forget() }

    public func fetch() async throws -> TrainStatus {
        try await fetch(now: Date())
    }

    /// The portal's site is on the internet too, so asking costs data on every network. Off a train it answers with
    /// nothing, and is then left alone for five minutes or until another network is joined. On board the trip is
    /// asked for twice a minute; only the router, which is on the train, on every poll.
    func fetch(now: Date) async throws -> TrainStatus {
        guard !memory.isPaused("journey", at: now) else { throw ProviderError.missingResource("journey") }
        var lastError: Error = ProviderError.missingResource("journey")
        for host in Self.hosts {
            let journey: Data
            do {
                journey = try await memory.load(URL(string: "https://\(host)\(Self.path)")!, maxAge: 30, now: now, loader: loader)
            } catch {
                lastError = error
                continue
            }
            guard !journey.isEmpty else {
                // A gap in a trip that just answered isn't the end of it.
                if memory.marked("journey").map({ now.timeIntervalSince($0) > 10 * 60 }) ?? true {
                    memory.pause("journey", until: now.addingTimeInterval(5 * 60))
                }
                throw ProviderError.missingResource("journey")
            }
            let status = try Self.parse(journey: journey, fix: await fix(now: now))
            memory.mark("journey", at: now)
            return status
        }
        throw lastError
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
        let listed = (journey.stops ?? []).filter { $0.station?.name?.nilIfEmpty != nil }
        guard !listed.isEmpty else { throw ProviderError.missingResource("stops") }

        // "REAL" marks a time that has happened: every stop up to the last one left is behind the train, and so is
        // every stop before one it has arrived at.
        let left = listed.lastIndex { $0.departureTime?.timeType == "REAL" }.map { $0 + 1 } ?? 0
        let reached = listed.lastIndex { $0.arrivalTime?.timeType == "REAL" } ?? 0
        let behind = max(left, reached)

        let stops = listed.enumerated().map { index, stop in
            Stop(
                id: stop.station?.evaNo?.nilIfEmpty ?? stop.station?.name ?? "",
                name: stop.station?.name ?? "",
                scheduledArrival: stop.arrivalTime?.scheduled,
                expectedArrival: stop.arrivalTime?.expected,
                scheduledDeparture: stop.departureTime?.scheduled,
                expectedDeparture: stop.departureTime?.expected,
                track: stop.track?.prediction?.nilIfEmpty ?? stop.track?.target?.nilIfEmpty,
                scheduledTrack: stop.track?.target?.nilIfEmpty,
                passed: index < behind,
                delayReasons: (stop.messages ?? []).filter { $0.type == "CUSTOMER_REASON" }
                    .compactMap { $0.textShort?.nilIfEmpty ?? $0.text?.nilIfEmpty },
                coordinate: Coordinate(stop.station?.position?.latitude, stop.station?.position?.longitude),
                cancelled: stop.canceled == true || stop.status == "Canceled"
            )
        }

        // "RE 80 (4711)": the line, which is what the train is called, and the number that tells it apart.
        let number = journey.no?.value.map { String(Int($0)) }
        let line = journey.name?.nilIfEmpty ?? journey.category?.nilIfEmpty
        let trainName = switch (line, number) {
        case (let line?, let number?): line.hasSuffix(number) ? line : "\(line) (\(number))"
        case (let line?, nil): line
        default: nil as String?
        }
        // A fix the router has had for a while says where the train was.
        let fresh = fix.flatMap { $0.age < 30 ? $0 : nil }

        return TrainStatus(
            provider: "DB Regio",
            trainName: trainName,
            destination: stops.last { !$0.cancelled }?.name,
            speed: fresh?.speed,
            stops: stops,
            nextStopID: stops.first { !$0.passed && !$0.cancelled }?.id,
            portal: .portal("Regio Guide", "https://regio-guide.de"),
            position: fresh?.coordinate
        )
    }

    struct Journey: Decodable {
        /// e.g. "RE 80"
        let name: String?
        let category: String?
        /// The train number.
        let no: OEBBRailnet.LenientDouble?
        let stops: [Stop]?

        struct Stop: Decodable {
            let status: String?
            let canceled: Bool?
            let station: Station?
            let track: Track?
            let arrivalTime: Time?
            let departureTime: Time?
            let messages: [Message]?
        }

        struct Station: Decodable {
            let evaNo: String?
            let name: String?
            let position: Position?
        }

        struct Position: Decodable {
            let latitude: Double?
            let longitude: Double?
        }

        struct Track: Decodable {
            let target: String?
            let prediction: String?
        }

        struct Time: Decodable {
            /// ISO 8601, with an offset or in UTC with milliseconds, depending on the train.
            let target: String?
            let predicted: String?
            let targetTimeInMs: Double?
            let predictedTimeInMs: Double?
            /// "SCHEDULE": timetable only, "PREVIEW": forecast, "REAL": happened.
            let timeType: String?

            var scheduled: Date? { date(targetTimeInMs, target) }
            /// Nothing for a time that's only the timetable's again.
            var expected: Date? { timeType == "SCHEDULE" ? nil : date(predictedTimeInMs, predicted) }

            private func date(_ milliseconds: Double?, _ text: String?) -> Date? {
                if let milliseconds, milliseconds > 0 { return Date(timeIntervalSince1970: milliseconds / 1000) }
                return text.flatMap(Date.init(portal:))
            }
        }

        struct Message: Decodable {
            let type: String?
            let text: String?
            let textShort: String?
        }
    }
}
