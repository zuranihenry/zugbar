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
    /// The route by posted speed, worked out while the map shows track speeds.
    var trackStretches: [TrackSpeeds.Stretch] = []
    /// Keeps the map centered on the train as it moves.
    var followsTrain = false {
        didSet {
            if !followsTrain { (shownDistance, shownDistanceAt, closeInOverride) = (nil, nil, nil) }
        }
    }
    /// Zoom while following, as camera distance in meters; kept when the user zooms.
    @ObservationIgnored var followDistance: Double = 40_000
    /// The camera distance following shows: `followDistance`, or closer in while the train crawls or nears a stop.
    @ObservationIgnored private var shownDistance: Double?
    @ObservationIgnored private var shownDistanceAt: Date?
    /// Whether following is zoomed in on its own; a zoom the user picks then lasts only until the train speeds up
    /// or leaves the stop, and their usual zoom comes back.
    @ObservationIgnored private var closingIn = false
    @ObservationIgnored private var closeInOverride: Double?
    /// Last time the user moved or zoomed the map; following pauses briefly after that.
    @ObservationIgnored var touchedAt: Date = .distantPast
    /// Counts camera moves the app itself started, so those changes don't count as user input.
    @ObservationIgnored var programmaticMoves = 0
    var movingProgrammatically: Bool { programmaticMoves > 0 }
    /// Where the map is currently centered, and how far out, as reported by the map itself.
    @ObservationIgnored var center: Coordinate?
    @ObservationIgnored var cameraDistance: Double?
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

    /// The camera distance following currently puts the map at.
    var followingDistance: Double { shownDistance ?? followDistance }

    /// The user zoomed the map to this camera distance, with a gesture or the buttons.
    func userZoomed(to distance: Double) {
        guard followsTrain else {
            followDistance = distance
            return
        }
        shownDistance = distance
        if closingIn { closeInOverride = distance } else { followDistance = distance }
    }

    /// The camera distance for the next frame while following: eased toward `closeIn` (from `MapZoom`) when that's
    /// closer than the user's zoom, and back to it once it isn't.
    func cameraDistance(closeIn: Double?, at date: Date) -> Double {
        closingIn = closeIn.map { $0 < followDistance } ?? false
        if !closingIn { closeInOverride = nil }
        let wanted = closeInOverride ?? (closingIn ? closeIn ?? followDistance : followDistance)
        // At most a frame or so at once: after a pause the map eases on instead of jumping, which would also
        // look like the user zooming.
        let elapsed = shownDistanceAt.map { min(max(date.timeIntervalSince($0), 0), 0.05) } ?? 0
        shownDistanceAt = date
        let shown = MapZoom.eased(from: followingDistance, to: wanted, elapsed: elapsed)
        shownDistance = shown
        return shown
    }

    /// After an animated turn, continue from where it ended instead of easing again.
    func setCameraHeading(_ heading: Double, at date: Date) {
        shownHeading = heading
        shownHeadingAt = date
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
