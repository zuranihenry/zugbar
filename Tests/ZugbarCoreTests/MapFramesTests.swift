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

    @Test func aFastTrainUpCloseGetsAFramePerPoint() {
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: 20.4) == 21)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: 500) == 30)
    }

    @Test func anUnknownScaleSavesPower() {
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: nil) == 10)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: .infinity) == 10)
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: false, pointsPerSecond: .nan) == 10)
    }

    @Test func zoomingStaysSmooth() {
        #expect(MapFrames.perSecond(onBattery: true, lowPowerMode: true, pointsPerSecond: 1, zooming: true) == 30)
    }

    @Test func speedOnScreenFollowsTheMapsScale() throws {
        // 144 km/h is 40 m/s.
        #expect(try #require(MapFrames.pointsPerSecond(speed: 144, metersPerPoint: 20)) == 2)
        #expect(try #require(MapFrames.pointsPerSecond(speed: 144, metersPerPoint: 2)) == 20)
        #expect(MapFrames.pointsPerSecond(speed: -3, metersPerPoint: 2) == 0)
        #expect(MapFrames.pointsPerSecond(speed: nil, metersPerPoint: 2) == nil)
        #expect(MapFrames.pointsPerSecond(speed: 144, metersPerPoint: nil) == nil)
        #expect(MapFrames.pointsPerSecond(speed: 144, metersPerPoint: 0) == nil)
    }
}
