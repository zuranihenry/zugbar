import Foundation

/// How close the map zooms in on its own while following a train: closer as the train slows to a crawl or nears
/// its next stop, so pulling into a station shows the station instead of the whole region.
public enum MapZoom {
    /// The closest the map goes on its own, as camera distance in meters.
    static let closest = 1_500.0

    /// Camera distance for a train at `speed` km/h that is `toNextStop` meters from its next stop; it only applies
    /// where it's closer than the user's own zoom. Nil when neither is known.
    public static func closeIn(speed: Int?, toNextStop meters: Double?) -> Double? {
        // Grows with the square of the speed: 3 km at 10 km/h, 15 at 30, about 40 at 50.
        let bySpeed = speed.map { closest * (1 + pow(Double(max($0, 0)) / 10, 2)) }
        // Wide enough to keep the stop in view with the train in the middle.
        let byStop = meters.map { max(closest, $0 * 3) }
        return [bySpeed, byStop].compactMap { $0 }.min()
    }

    /// One step from the shown camera distance toward the wanted one, `elapsed` seconds after the last.
    /// Moves in even steps of scale and at most doubles or halves in 1.5 s, so it never looks like a jump.
    public static func eased(from shown: Double, to wanted: Double, elapsed: TimeInterval) -> Double {
        let gap = log(wanted / shown)
        let limit = log(2) / 1.5 * elapsed
        return shown * exp(min(max(gap * (1 - exp(-elapsed / 1.5)), -limit), limit))
    }
}
