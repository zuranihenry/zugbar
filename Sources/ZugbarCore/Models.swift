import Foundation

public struct TrainStatus: Sendable, Equatable {
    public var provider: String
    public var trainName: String?
    public var destination: String?
    /// km/h; `nil` when there's no GPS fix or the source has no live position.
    public var speed: Int?
    public var stops: [Stop]
    public var nextStopID: String?
    /// 0...1
    public var progress: Double?
    /// e.g. "ICE 4 · Tz 9018 „Gießen“"
    public var vehicle: String?
    /// 1 or 2, when the portal knows which car you're in.
    public var wagonClass: Int?
    public var internet: Internet?
    /// The on-board portal's own web page, when connected to one.
    public var portal: TrainLink?
    /// GPS position from the on-board portal.
    public var position: Coordinate?
    /// The track the train follows, when the source provides it (Transitous).
    public var route: Route?

    public init(
        provider: String,
        trainName: String? = nil,
        destination: String? = nil,
        speed: Int? = nil,
        stops: [Stop] = [],
        nextStopID: String? = nil,
        progress: Double? = nil,
        vehicle: String? = nil,
        wagonClass: Int? = nil,
        internet: Internet? = nil,
        portal: TrainLink? = nil,
        position: Coordinate? = nil,
        route: Route? = nil
    ) {
        self.provider = provider
        self.trainName = trainName
        self.destination = destination
        self.speed = speed
        self.stops = stops
        self.nextStopID = nextStopID
        self.progress = progress
        self.vehicle = vehicle
        self.wagonClass = wagonClass
        self.internet = internet
        self.portal = portal
        self.position = position
        self.route = route
    }

    /// Average km/h between the last and the next stop, for trains without live speed. 0 while standing at a stop.
    public func estimatedSpeed(at now: Date) -> Int? {
        guard let nextIndex = stops.firstIndex(where: { !$0.passed }), nextIndex > 0 else { return nil }
        let next = stops[nextIndex], previous = stops[nextIndex - 1]
        if next.isCurrent(at: now) || previous.isCurrent(at: now) { return 0 }
        if let estimate = routeEstimate(at: now), now >= estimate.departure {
            let speed = estimate.averageSpeed
            return speed <= 350 ? speed : nil
        }
        guard let from = previous.coordinate, let to = next.coordinate,
              let start = previous.departure, let end = next.arrival, end > start, now >= start
        else { return nil }
        // Straight-line distance plus 10% for curves.
        let kilometers = from.distance(to: to) * 1.1
        let speed = Int((kilometers / (end.timeIntervalSince(start) / 3600)).rounded())
        return speed <= 350 ? speed : nil
    }

    /// GPS position if available, otherwise interpolated from the timetable between the last and next stop.
    public func position(at now: Date) -> Coordinate? {
        if let position { return position }
        if let route, let estimate = routeEstimate(at: now) {
            let fraction = min(max(now.timeIntervalSince(estimate.departure) / estimate.duration, 0), 1)
            return route.coordinate(at: estimate.startDistance + estimate.sectionLength * fraction)
        }
        guard let nextIndex = stops.firstIndex(where: { !$0.passed }) else { return stops.last?.coordinate }
        let next = stops[nextIndex]
        guard nextIndex > 0 else { return next.coordinate }
        let previous = stops[nextIndex - 1]
        guard let from = previous.coordinate, let to = next.coordinate else { return next.coordinate ?? previous.coordinate }
        guard let start = previous.departure, let end = next.arrival, end > start else { return from }
        let fraction = min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
        return Coordinate(
            latitude: from.latitude + (to.latitude - from.latitude) * fraction,
            longitude: from.longitude + (to.longitude - from.longitude) * fraction
        )
    }

    public var nextStop: Stop? {
        stops.first { $0.id == nextStopID } ?? stops.first { !$0.passed }
    }

    /// e.g. ("ICE", "503") from "ICE 503", ("RE", "4589") from "RE70 (4589)"; nil for S-Bahn lines without a number.
    public var trainNumber: (category: String, number: String)? {
        guard let trainName else { return nil }
        let category = String(trainName.prefix { $0.isLetter })
        guard !category.isEmpty else { return nil }
        if let open = trainName.firstIndex(of: "("), let close = trainName.firstIndex(of: ")"), open < close {
            let inner = trainName[trainName.index(after: open)..<close]
            if !inner.isEmpty, inner.allSatisfy(\.isNumber) { return (category, String(inner)) }
        }
        guard let last = trainName.split(separator: " ").last, last.allSatisfy(\.isNumber),
              trainName.contains(" ")
        else { return nil }
        return (category, String(last))
    }

    public var links: [TrainLink] {
        var links: [TrainLink] = []
        if let portal { links.append(portal) }
        guard let (category, number) = trainNumber else { return links }

        let name = "\(category) \(number)"
        if let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "https://bahn.expert/details/\(path)") {
            links.append(TrainLink(kind: .bahnExpert, url: url))
        }
        if let url = URL(string: "https://www.zugfinder.net/de/zug-\(category)_\(number)") {
            links.append(TrainLink(kind: .zugfinder, url: url))
        }
        return links
    }
}

public struct TrainLink: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case portal(String), bahnExpert, zugfinder
    }

    public let kind: Kind
    public let url: URL
    public var id: URL { url }

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = url
    }

    static func portal(_ name: String, _ url: String) -> TrainLink {
        TrainLink(kind: .portal(name), url: URL(string: url)!)
    }
}

public struct Coordinate: Sendable, Equatable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in km.
    public func distance(to other: Coordinate) -> Double {
        let (φ1, φ2) = (latitude * .pi / 180, other.latitude * .pi / 180)
        let Δφ = φ2 - φ1
        let Δλ = (other.longitude - longitude) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 6371 * 2 * asin(min(1, sqrt(a)))
    }

    /// `nil` for the 0,0 placeholders some portals send.
    init?(_ latitude: Double?, _ longitude: Double?) {
        guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }
}

public struct Internet: Sendable, Equatable {
    public enum Quality: Sendable, Equatable {
        case good, weak, none
    }

    public var current: Quality
    public var next: Quality?
    /// When `next` takes over.
    public var nextChange: Date?

    public init(current: Quality, next: Quality? = nil, nextChange: Date? = nil) {
        self.current = current
        self.next = next
        self.nextChange = nextChange
    }
}

public struct Stop: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var scheduledArrival: Date?
    public var expectedArrival: Date?
    public var scheduledDeparture: Date?
    public var expectedDeparture: Date?
    public var track: String?
    public var passed: Bool
    /// e.g. "Reparatur am Zug"
    public var delayReasons: [String]
    public var coordinate: Coordinate?

    public init(
        id: String,
        name: String,
        scheduledArrival: Date? = nil,
        expectedArrival: Date? = nil,
        scheduledDeparture: Date? = nil,
        expectedDeparture: Date? = nil,
        track: String? = nil,
        passed: Bool = false,
        delayReasons: [String] = [],
        coordinate: Coordinate? = nil
    ) {
        self.id = id
        self.name = name
        self.scheduledArrival = scheduledArrival
        self.expectedArrival = expectedArrival
        self.scheduledDeparture = scheduledDeparture
        self.expectedDeparture = expectedDeparture
        self.track = track
        self.passed = passed
        self.delayReasons = delayReasons
        self.coordinate = coordinate
    }

    public var arrival: Date? { expectedArrival ?? scheduledArrival }
    public var departure: Date? { expectedDeparture ?? scheduledDeparture }

    /// Arrival delay in minutes, or departure delay at the first stop.
    public var delayMinutes: Int? {
        if let s = scheduledArrival, let e = expectedArrival { return minutes(from: s, to: e) }
        if let s = scheduledDeparture, let e = expectedDeparture { return minutes(from: s, to: e) }
        return nil
    }

    /// Whether the train is standing at this stop right now.
    public func isCurrent(at now: Date) -> Bool {
        guard let arrival, arrival <= now else { return false }
        guard let departure else { return true }
        return now < departure
    }

    func shifted(by interval: TimeInterval) -> Stop {
        var copy = self
        copy.scheduledArrival = scheduledArrival?.addingTimeInterval(interval)
        copy.expectedArrival = expectedArrival?.addingTimeInterval(interval)
        copy.scheduledDeparture = scheduledDeparture?.addingTimeInterval(interval)
        copy.expectedDeparture = expectedDeparture?.addingTimeInterval(interval)
        return copy
    }
}

func minutes(from start: Date, to end: Date) -> Int {
    Int((end.timeIntervalSince(start) / 60).rounded())
}
