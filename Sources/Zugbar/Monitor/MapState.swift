import MapKit
import Observation
import SwiftUI
import ZugbarCore

/// The map's camera and the bookkeeping that tells the user's gestures apart from following the train.
@MainActor
@Observable
final class MapState {
    /// Map camera; `.automatic` fits the whole route.
    var camera: MapCameraPosition = .automatic
    /// Keeps the map centered on the train as it moves.
    var followsTrain = false
    /// Zoom while following, as camera distance in meters; kept when the user zooms.
    @ObservationIgnored var followDistance: Double = 40_000
    /// Last time the user moved or zoomed the map; following pauses briefly after that.
    @ObservationIgnored var touchedAt: Date = .distantPast
    /// Counts camera moves the app itself started, so those changes don't count as user input.
    @ObservationIgnored var programmaticMoves = 0
    var movingProgrammatically: Bool { programmaticMoves > 0 }
    /// Where the map is currently centered, as reported by the map itself.
    @ObservationIgnored var center: Coordinate?
    /// Where following last put the camera; the user panning shows up as a difference to this.
    @ObservationIgnored var expectedCenter: Coordinate?
    /// Whether the current gesture changed the zoom; zooming never ends following.
    @ObservationIgnored var gestureZoomed = false
    /// Direction of travel for a map turned with the train; follows the marker, not the raw fixes.
    @ObservationIgnored private(set) var heading = Heading()

    /// The heading the camera shows, eased toward the wanted one so switching heading-up turns the map
    /// smoothly while it keeps following the train.
    @ObservationIgnored private var shownHeading = 0.0
    @ObservationIgnored private var shownHeadingAt: Date?

    func trainMoved(to position: Coordinate, at date: Date) {
        heading.update(position, at: date)
    }

    func cameraHeading(toward target: Double, at date: Date) -> Double {
        let elapsed = shownHeadingAt.map { min(max(date.timeIntervalSince($0), 0), 1) } ?? 1
        shownHeadingAt = date
        let turn = (target - shownHeading + 540).truncatingRemainder(dividingBy: 360) - 180
        // About 90 % of the way in half a second at 30 frames a second.
        shownHeading = (shownHeading + turn * (1 - exp(-elapsed / 0.2)) + 360).truncatingRemainder(dividingBy: 360)
        return shownHeading
    }
}
