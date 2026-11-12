import Foundation

/// How often the train is placed on a map that shows it. Each frame while following also moves the camera, and
/// the map draws itself again: that drawing is nearly all the app costs, and it grows with the frames.
public enum MapFrames {
    /// Frames a second on mains power.
    public static let smooth = 30
    /// Frames a second while saving power, unless the train crosses the screen faster than that.
    public static let saving = 10

    /// Frames a second for a train crossing the map at `pointsPerSecond` on screen; nil when the map's scale isn't
    /// known. On battery or in Low Power Mode that's one frame per point the train moves, between `saving` and
    /// `smooth`: at most zooms a fast train moves a point or two a second, so fewer frames show the same thing.
    /// While the camera eases its zoom, every frame counts, and the pace stays smooth.
    public static func perSecond(onBattery: Bool, lowPowerMode: Bool, pointsPerSecond: Double?, zooming: Bool = false) -> Int {
        guard onBattery || lowPowerMode, !zooming else { return smooth }
        guard let pointsPerSecond, pointsPerSecond.isFinite else { return saving }
        return Int(min(max(pointsPerSecond.rounded(.up), Double(saving)), Double(smooth)))
    }

    /// How fast a train at `speed` km/h crosses a map that shows `metersPerPoint`; nil when either isn't known.
    public static func pointsPerSecond(speed: Int?, metersPerPoint: Double?) -> Double? {
        guard let speed, let metersPerPoint, metersPerPoint > 0 else { return nil }
        return Double(max(speed, 0)) / 3.6 / metersPerPoint
    }
}
