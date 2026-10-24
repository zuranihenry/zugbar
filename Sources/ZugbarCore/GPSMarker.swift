import Foundation

/// Where the map marker shows a train with GPS. On its route and moving, it goes on from each fix at the reported
/// speed, for up to `reckonTime` and not past the next stop, since a portal's GPS can freeze at speed for minutes. A
/// new fix ahead is caught up with in `catchUp`; one behind, which is often just late, slows the marker to half speed
/// until they meet, so it never runs backwards. Without a route it glides from where it is to each new fix, running
/// about one fix behind at an even pace.
public struct GPSMarker: Sendable {
    /// The newest fix and when it came.
    private var fix: (coordinate: Coordinate, time: Date)?
    /// Without a route: from where the marker was when the newest fix came.
    private var glide: (from: Coordinate, duration: TimeInterval)?
    /// With a route: the newest fix on it, and how the marker gets onto the track reckoned from it.
    private var track: Track?
    /// Meters gone on from the fix until `pace.since`, and the reported speed since then.
    private var travelled = 0.0
    private var pace: (speed: Int?, since: Date)?

    private struct Track: Sendable {
        let route: Route
        /// Meters along the route.
        let along: Double
        /// Meters along the route of the next stop, or of the route's end.
        let limit: Double
        /// How far the marker was ahead of the fix along the route when it came, in meters; negative when behind.
        let lead: Double
        /// A lead taken up over twice its length of travel instead of within `catchUp`, so the marker never goes back.
        let slowsDown: Bool
        /// How far the fix and the marker were off the track when the fix came, in degrees; blended within `catchUp`.
        let offset: (latitude: Double, longitude: Double)
        let shownOffset: (latitude: Double, longitude: Double)
    }

    /// Seconds to get onto a new fix.
    static let catchUp: TimeInterval = 10
    /// Going on from a fix for at most this long.
    static let reckonTime: TimeInterval = 120
    /// Slower than this, in km/h, the train may be stopping, so the marker waits for the next fix.
    static let reckonSpeed = 30
    /// From this speed in km/h on, the marker doesn't go back to a fix behind it: it waits for the train instead.
    static let movingSpeed = 5
    /// Longer gaps between fixes (sleep, an outage) aren't glided over, unless the marker went on meanwhile.
    static let longGap: TimeInterval = 30
    /// Bigger jumps (another train, a long gap) aren't animated, in km.
    static let longJump = 5.0

    public init() {}

    /// Takes the train's current fix and speed; called every frame, so an equal fix counts as unchanged.
    public mutating func update(_ coordinate: Coordinate, speed: Int?, route: Route?, nextStop: Coordinate?, at date: Date) {
        if let fix, fix.coordinate == coordinate {
            if pace?.speed != speed {
                travelled = distance(at: date)
                pace = (speed, date)
            }
            return
        }
        let wentOn = distance(at: date) > 0
        let gap = fix.map { date.timeIntervalSince($0.time) }
        // Big jumps (first fix, another train) and long gaps without going on (sleep, an outage) aren't animated.
        let shown = position(at: date).flatMap { shown -> Coordinate? in
            guard let gap, shown.distance(to: coordinate) < Self.longJump, gap <= Self.longGap || wentOn else { return nil }
            return shown
        }
        let previous = fix?.coordinate
        fix = (coordinate, date)
        travelled = 0
        pace = (speed, date)
        track = route.flatMap { Self.track(of: coordinate, after: previous, shown: shown, speed: speed, on: $0, nextStop: nextStop) }
        glide = track == nil ? shown.map { ($0, min(max(gap ?? 0, 1), Self.longGap)) } : nil
    }

    /// Where the marker is at `date`.
    public func position(at date: Date) -> Coordinate? {
        guard let fix else { return nil }
        let elapsed = max(date.timeIntervalSince(fix.time), 0)
        if let track {
            let reckoned = distance(at: date)
            let lead = track.slowsDown
                ? max(track.lead - reckoned / 2, 0)
                : track.lead * max(1 - elapsed / Self.catchUp, 0)
            guard let point = track.route.coordinate(at: track.along + reckoned + lead) else { return fix.coordinate }
            let blend = min(elapsed / Self.catchUp, 1)
            return Coordinate(
                latitude: point.latitude + track.shownOffset.latitude + (track.offset.latitude - track.shownOffset.latitude) * blend,
                longitude: point.longitude + track.shownOffset.longitude + (track.offset.longitude - track.shownOffset.longitude) * blend
            )
        }
        if let glide, elapsed < glide.duration {
            let t = elapsed / glide.duration
            return Coordinate(
                latitude: glide.from.latitude + (fix.coordinate.latitude - glide.from.latitude) * t,
                longitude: glide.from.longitude + (fix.coordinate.longitude - glide.from.longitude) * t
            )
        }
        return fix.coordinate
    }

    /// Meters the train has gone on from the newest fix by `date`, from the speeds reported since.
    private func distance(at date: Date) -> Double {
        guard let fix, let track, let pace else { return 0 }
        let end = min(date, fix.time.addingTimeInterval(Self.reckonTime))
        var meters = travelled
        if end > pace.since, let speed = pace.speed, speed >= Self.reckonSpeed {
            meters += Double(speed) / 3.6 * end.timeIntervalSince(pace.since)
        }
        return min(meters, max(track.limit - track.along, 0))
    }

    private static func track(
        of coordinate: Coordinate, after previous: Coordinate?, shown: Coordinate?, speed: Int?, on route: Route, nextStop: Coordinate?
    ) -> Track? {
        // The way the train goes, so where the route comes back the same way after reversing, the fix lands on the right
        // leg. A late fix points the other way, so the nearest leg is taken when none goes the train's way there.
        let step = previous.map { $0.distance(to: coordinate) } ?? 0
        let heading = step > 0.05 && step < Self.longJump ? previous?.bearing(to: coordinate) : nil
        // Long pieces are straight lines between stops where the feed has no shape.
        func onTrack(_ position: (along: Double, offset: Double, pieceLength: Double)) -> Bool {
            position.offset < (position.pieceLength > 2_000 ? 1.5 : 0.5)
        }
        func project(_ coordinate: Coordinate) -> (along: Double, offset: Double, pieceLength: Double) {
            let position = route.projection(of: coordinate, heading: heading)
            return heading == nil || onTrack(position) ? position : route.projection(of: coordinate)
        }
        let position = project(coordinate)
        guard onTrack(position), let point = route.coordinate(at: position.along) else { return nil }
        let offset = (latitude: coordinate.latitude - point.latitude, longitude: coordinate.longitude - point.longitude)
        // Where the route passes the stop twice, the leg ahead, if only to the nearest point.
        let stop = nextStop.map { stop in
            let along = route.projection(of: stop).along
            return along >= position.along ? along : route.distance(of: stop, from: position.along)
        }
        var lead = 0.0, shownOffset = offset
        if let shown {
            let along = project(shown).along
            if let point = route.coordinate(at: along) {
                lead = along - position.along
                shownOffset = (shown.latitude - point.latitude, shown.longitude - point.longitude)
            }
        }
        return Track(
            route: route, along: position.along, limit: stop ?? route.length, lead: lead,
            slowsDown: lead > 0 && (speed ?? 0) >= Self.movingSpeed, offset: offset, shownOffset: shownOffset
        )
    }
}
