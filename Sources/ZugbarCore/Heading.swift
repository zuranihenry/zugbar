import Foundation

/// The train's direction of travel for turning the map with it. Taken over the last stretch of track instead of
/// between single fixes, so GPS jitter and standing at a platform don't spin the map, and eased over a few
/// seconds, so curves turn it gently.
public struct Heading: Sendable {
    /// Smoothed heading in degrees clockwise from north; `nil` until the train has moved far enough.
    public private(set) var degrees: Double?
    private var anchor: Coordinate?
    private var target: Double?
    private var updated: Date?

    /// How far the train must move before its direction counts.
    static let stretch = 60.0
    /// Time constant of the easing, in seconds.
    static let easing = 2.5

    public init() {}

    public mutating func update(_ position: Coordinate, at date: Date) {
        if let anchor {
            let meters = anchor.distance(to: position) * 1000
            if meters > 5_000 {
                // Another train or a jump after a gap: start over rather than turn towards it.
                self = Heading()
                self.anchor = position
                return
            }
            if meters >= Self.stretch {
                target = anchor.bearing(to: position)
                self.anchor = position
            }
        } else {
            anchor = position
        }
        guard let target else { return }
        guard let degrees, let updated else {
            degrees = target
            updated = date
            return
        }
        let factor = 1 - exp(-max(date.timeIntervalSince(updated), 0) / Self.easing)
        let turn = (target - degrees + 540).truncatingRemainder(dividingBy: 360) - 180
        self.degrees = (degrees + turn * factor + 360).truncatingRemainder(dividingBy: 360)
        self.updated = date
    }
}
