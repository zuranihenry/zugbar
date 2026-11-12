import Foundation
import Testing
@testable import ZugbarCore

struct MapFramesTests {
    @Test func staysSmoothOnMainsPower() {
        #expect(MapFrames.perSecond(onBattery: false, lowPowerMode: false, pointsPerSecond: 1) == 30)
        #expect(MapFrames.perSecond(onBattery: false, lowPowerMode: false, pointsPerSecond: nil) == 30)
    }

    @Test func slowsDownOnBatteryAndInLowPowerMode() {
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: 1.6) == 10)
        // Low Power Mode can be on while plugged in.
        #expect(MapFrames.perSecond(onBattery: false, lowPowerMode: true, pointsPerSecond: 1.6) == 10)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: true, pointsPerSecond: 0) == 10)
    }

    @Test func fastMovementGetsAFramePerPoint() {
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: 20.4) == 21)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: 500) == 30)
    }

    @Test func unknownMovementSavesPower() {
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: nil) == 10)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: .infinity) == 10)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: .nan) == 10)
    }
}

struct MapMotionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let origin = Coordinate(latitude: 0, longitude: 10)

    /// `meters` north of the origin.
    private func north(_ meters: Double) -> Coordinate {
        Coordinate(latitude: meters / 111_195, longitude: 10)
    }

    /// A train moving north at `metersPerSecond`, placed `frames` times a second for a second.
    private func moving(_ metersPerSecond: Double, frames: Int = 10) -> MapMotion {
        var motion = MapMotion()
        for frame in 0...frames {
            let seconds = Double(frame) / Double(frames)
            motion.trainMoved(to: north(metersPerSecond * seconds), at: start.addingTimeInterval(seconds))
        }
        return motion
    }

    @Test func theMarkersOwnPaceCountsWithoutAReportedSpeed() throws {
        // 40 m/s on a map showing 20 m a point, and zoomed in to 2 m a point.
        let motion = moving(40)
        let far = try #require(motion.pointsPerSecond(metersPerPoint: 20, radius: 500, at: start.addingTimeInterval(1)))
        let near = try #require(motion.pointsPerSecond(metersPerPoint: 2, radius: 500, at: start.addingTimeInterval(1)))
        #expect(abs(far - 2) < 0.05)
        #expect(abs(near - 20) < 0.5)
    }

    @Test func unknownUntilTheTrainWasPlacedTwiceAndTheScaleIsKnown() {
        var motion = MapMotion()
        #expect(motion.pointsPerSecond(metersPerPoint: 20, radius: 500, at: start) == nil)
        motion.trainMoved(to: origin, at: start)
        #expect(motion.pointsPerSecond(metersPerPoint: 20, radius: 500, at: start) == nil)
        motion.trainMoved(to: origin, at: start.addingTimeInterval(0.1))
        #expect(motion.pointsPerSecond(metersPerPoint: 20, radius: 500, at: start) == 0)
        #expect(motion.pointsPerSecond(metersPerPoint: nil, radius: 500, at: start) == nil)
        #expect(motion.pointsPerSecond(metersPerPoint: 0, radius: 500, at: start) == nil)
    }

    @Test func aPauseIsNotAJump() {
        var motion = moving(40)
        // Placed again after the Mac slept: far away, but not fast.
        motion.trainMoved(to: north(50_000), at: start.addingTimeInterval(600))
        #expect(motion.pointsPerSecond(metersPerPoint: 20, radius: 500, at: start.addingTimeInterval(600)) == nil)
    }

    @Test func theSecondBetweenFramesOfAHiddenMapStillMeasures() throws {
        let motion = moving(40, frames: 1)
        let points = try #require(motion.pointsPerSecond(metersPerPoint: 20, radius: 500, at: start.addingTimeInterval(1)))
        #expect(abs(points - 2) < 0.05)
    }

    @Test func closingInSlowlyNearAStopBarelyMovesTheMap() throws {
        // 100 km/h, 6 km before the stop: the camera, three times the way to the stop up, comes down 84 m a second.
        var motion = moving(28)
        motion.cameraMoved(distance: 18_000, heading: 0, at: start.addingTimeInterval(0.9))
        motion.cameraMoved(distance: 18_000 - 8.4, heading: 0, at: start.addingTimeInterval(1))
        let points = try #require(motion.pointsPerSecond(metersPerPoint: 15, radius: 500, at: start.addingTimeInterval(1)))
        #expect(points < 5)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: points) == 10)
    }

    @Test func aQuickZoomMovesTheEdgeFast() throws {
        // Halving in 1.5 s, as fast as following ever zooms.
        var motion = moving(0)
        motion.cameraMoved(distance: 40_000, heading: 0, at: start.addingTimeInterval(0.9))
        motion.cameraMoved(distance: 40_000 * exp(-log(2) / 15), heading: 0, at: start.addingTimeInterval(1))
        let points = try #require(motion.pointsPerSecond(metersPerPoint: 30, radius: 500, at: start.addingTimeInterval(1)))
        #expect(abs(points - 231) < 1)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: points) == 30)
    }

    @Test func aTurningMapCountsAtItsEdge() throws {
        // 3° a second, 500 points from the middle: 26 points a second. Across north, too.
        var motion = moving(0)
        motion.cameraMoved(distance: 40_000, heading: 359.9, at: start.addingTimeInterval(0.9))
        motion.cameraMoved(distance: 40_000, heading: 0.2, at: start.addingTimeInterval(1))
        let points = try #require(motion.pointsPerSecond(metersPerPoint: 30, radius: 500, at: start.addingTimeInterval(1)))
        #expect(abs(points - 26.2) < 0.1)
        // A smaller map's edge moves less.
        let small = try #require(motion.pointsPerSecond(metersPerPoint: 30, radius: 100, at: start.addingTimeInterval(1)))
        #expect(abs(small - 5.2) < 0.1)
    }

    @Test func aCameraLeftAloneNoLongerCounts() throws {
        var motion = moving(0)
        motion.cameraMoved(distance: 40_000, heading: 0, at: start.addingTimeInterval(0.9))
        motion.cameraMoved(distance: 30_000, heading: 40, at: start.addingTimeInterval(1))
        // Following ended; the train is still placed.
        #expect(motion.pointsPerSecond(metersPerPoint: 30, radius: 500, at: start.addingTimeInterval(2)) == 0)
        // Picked up again later: the first frame has nothing to compare with.
        motion.cameraMoved(distance: 5_000, heading: 90, at: start.addingTimeInterval(60))
        motion.trainMoved(to: origin, at: start.addingTimeInterval(59.9))
        motion.trainMoved(to: origin, at: start.addingTimeInterval(60))
        #expect(motion.pointsPerSecond(metersPerPoint: 30, radius: 500, at: start.addingTimeInterval(60)) == 0)
    }

    @Test func withoutTheMapsSizeOnlyTheTrainCounts() throws {
        var motion = moving(40)
        motion.cameraMoved(distance: 40_000, heading: 0, at: start.addingTimeInterval(0.9))
        motion.cameraMoved(distance: 30_000, heading: 40, at: start.addingTimeInterval(1))
        let points = try #require(motion.pointsPerSecond(metersPerPoint: 20, radius: nil, at: start.addingTimeInterval(1)))
        #expect(abs(points - 2) < 0.05)
    }
}
