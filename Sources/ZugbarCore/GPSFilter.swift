import Foundation

/// Holds the last good GPS fix while a new one lies behind the moving train. At speed the ICE portal sometimes
/// sends a fix from about a minute ago again, still marked valid and kilometres back, so the marker would glide back
/// and forth and speeds would be learned in the wrong place. Trains only reverse after standing, so standing starts
/// over, and a fix behind the train that lasts is taken after `giveUp`.
public struct GPSFilter: Sendable {
    /// The last fix let through, and when.
    private var last: (coordinate: Coordinate, time: Date)?
    /// Where the direction of travel is measured from, and the direction once the train has moved far enough.
    private var anchor: Coordinate?
    private var direction: Double?

    /// How far behind the train a fix must lie to be held, in meters; less is GPS jitter.
    static let tolerance = 100.0
    /// Below this speed in km/h the train counts as standing and may leave either way.
    static let movingSpeed = 5
    /// How far the train must move before its direction counts, in meters.
    static let stretch = 50.0
    /// After this long without a fix let through, the next one is taken wherever it is.
    static let giveUp: TimeInterval = 60

    public init() {}

    /// `position`, or the last good fix while `position` lies behind the moving train.
    public mutating func filter(_ position: Coordinate, speed: Int?, at date: Date) -> Coordinate {
        guard let last, date.timeIntervalSince(last.time) < Self.giveUp, let speed, speed >= Self.movingSpeed else {
            // The first fix, one after a long hold or gap, or a standing train: it may go either way from here.
            self = GPSFilter()
            accept(position, at: date)
            return position
        }
        if let direction {
            let meters = last.coordinate.distance(to: position) * 1000
            let along = meters * cos((last.coordinate.bearing(to: position) - direction) * .pi / 180)
            if along < -Self.tolerance { return last.coordinate }
        }
        accept(position, at: date)
        return position
    }

    private mutating func accept(_ position: Coordinate, at date: Date) {
        last = (position, date)
        guard let anchor else {
            anchor = position
            return
        }
        if anchor.distance(to: position) * 1000 >= Self.stretch {
            direction = anchor.bearing(to: position)
            self.anchor = position
        }
    }
}
