import Foundation

/// How often the train is placed on a map that shows it. Each frame while following also moves the camera, and
/// the map draws itself again: that drawing is nearly all the app costs, and it grows with the frames.
public enum MapFrames {
    /// Frames a second on mains power.
    public static let smooth = 30
    /// Frames a second while saving power, unless the train crosses the screen faster than that.
    public static let saving = 10

    /// Frames a second for a map whose content moves `pointsPerSecond` on screen (see `MapMotion`); nil when that
    /// isn't known. On battery or in Low Power Mode that's one frame per point of movement, between `saving` and
    /// `smooth`: at most zooms a fast train moves a point or two a second, so fewer frames show the same thing.
    public static func perSecond(onBattery: Bool, lowPowerMode: Bool, pointsPerSecond: Double?) -> Int {
        guard onBattery || lowPowerMode else { return smooth }
        guard let pointsPerSecond, pointsPerSecond.isFinite else { return saving }
        return Int(min(max(pointsPerSecond.rounded(.up), Double(saving)), Double(smooth)))
    }
}

/// How fast what a map shows moves on screen, measured from the frames themselves: the train along the map and,
/// while following, the camera zooming and turning, which move the map most at its edge. From the marker rather
/// than the reported speed, so it also holds for a train placed by its timetable.
public struct MapMotion: Sendable {
    private var train: (position: Coordinate, date: Date)?
    private var metersPerSecond: Double?
    private var camera: (distance: Double, heading: Double, date: Date)?
    /// Change of the camera distance's logarithm: 0.1 moves the edge a tenth of its distance from the middle.
    private var zoomPerSecond = 0.0
    private var degreesPerSecond = 0.0

    /// Frames further apart than this are a pause, not a movement to measure. Longer than the second between
    /// frames while no map shows, so the speed is known when one opens.
    static let pause: TimeInterval = 1.5
    /// A camera last moved longer ago than this stands still: following ended or waits for the user.
    static let cameraRest: TimeInterval = 0.5

    public init() {}

    /// The marker was placed at `position`.
    public mutating func trainMoved(to position: Coordinate, at date: Date) {
        defer { train = (position, date) }
        guard let train, case let elapsed = date.timeIntervalSince(train.date), elapsed > 0, elapsed <= Self.pause else {
            metersPerSecond = nil
            return
        }
        metersPerSecond = train.position.distance(to: position) * 1000 / elapsed
    }

    /// Following put the camera `distance` meters up, turned to `heading` degrees.
    public mutating func cameraMoved(distance: Double, heading: Double, at date: Date) {
        defer { camera = (distance, heading, date) }
        guard let camera, case let elapsed = date.timeIntervalSince(camera.date), elapsed > 0, elapsed <= Self.pause,
              distance > 0, camera.distance > 0
        else {
            (zoomPerSecond, degreesPerSecond) = (0, 0)
            return
        }
        zoomPerSecond = abs(log(distance / camera.distance)) / elapsed
        let turn = (heading - camera.heading + 540).truncatingRemainder(dividingBy: 360) - 180
        degreesPerSecond = abs(turn) / elapsed
    }

    /// Points a second the fastest part of the map moves at `date`: the train, plus the map's edge, `radius` points
    /// from the middle, while the camera zooms or turns. Nil while the train's pace or the map's scale isn't known.
    public func pointsPerSecond(metersPerPoint: Double?, radius: Double?, at date: Date) -> Double? {
        guard let metersPerSecond, let metersPerPoint, metersPerPoint > 0 else { return nil }
        var points = metersPerSecond / metersPerPoint
        if let camera, let radius, date.timeIntervalSince(camera.date) <= Self.cameraRest {
            points += (zoomPerSecond + degreesPerSecond * .pi / 180) * radius
        }
        return points
    }
}
