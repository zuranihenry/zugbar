import Foundation
import Testing
@testable import ZugbarCore

struct MapZoomTests {
    @Test func closesInAtAStandstill() {
        #expect(MapZoom.closeIn(speed: 0, toNextStop: nil) == 1_500)
        #expect(MapZoom.closeIn(speed: 0, toNextStop: 20) == 1_500)
        #expect(MapZoom.closeIn(speed: nil, toNextStop: nil) == nil)
    }

    @Test func staysOutWhileFastAndFarFromTheStop() throws {
        let zoom = try #require(MapZoom.closeIn(speed: 250, toNextStop: 60_000))
        #expect(zoom > 100_000)
    }

    @Test func crawlingZoomsInAnywhere() throws {
        let zoom = try #require(MapZoom.closeIn(speed: 15, toNextStop: 60_000))
        #expect(zoom < 5_000)
    }

    @Test func nearingAStopKeepsItInView() {
        #expect(MapZoom.closeIn(speed: 120, toNextStop: 4_000) == 12_000)
        #expect(MapZoom.closeIn(speed: nil, toNextStop: 2_000) == 6_000)
    }

    @Test func easesWithoutJumps() {
        // A frame at 30 Hz moves well under the 3 % the map takes for a zoom by the user.
        let step = MapZoom.eased(from: 40_000, to: 1_500, elapsed: 1.0 / 30)
        #expect(step < 40_000 && step > 40_000 * 0.97)
        // Gets there within seconds, and stays put once there.
        var shown = 40_000.0
        for _ in 0..<(30 * 15) { shown = MapZoom.eased(from: shown, to: 1_500, elapsed: 1.0 / 30) }
        #expect(abs(shown - 1_500) < 50)
        #expect(MapZoom.eased(from: 1_500, to: 1_500, elapsed: 0.1) == 1_500)
        // Back out the same way.
        let out = MapZoom.eased(from: 1_500, to: 40_000, elapsed: 1.0 / 30)
        #expect(out > 1_500 && out < 1_500 * 1.03)
    }
}
