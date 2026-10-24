import Foundation
import Testing
@testable import ZugbarCore

struct TrackSpeedsTests {
    // About 11 km due north, in two points: the lookups in between come from the step.
    let line = [Coordinate(latitude: 50, longitude: 8), Coordinate(latitude: 50.1, longitude: 8)]

    @Test func bands() {
        #expect(TrackSpeeds.band(of: nil) == nil)
        #expect(TrackSpeeds.band(of: 80) == 120)
        #expect(TrackSpeeds.band(of: 160) == 160)
        #expect(TrackSpeeds.band(of: 230) == 250)
        #expect(TrackSpeeds.band(of: 330) == 300)
    }

    @Test func splitsWhereTheLimitChanges() {
        // 160 for the first 3 km, then 280, with an unknown gap at the end.
        let stretches = TrackSpeeds.stretches(along: line) { point in
            point.latitude < 50.027 ? 160 : point.latitude < 50.09 ? 280 : nil
        }
        #expect(stretches.map(\.band) == [160, 300, nil])
        // No gaps: each stretch starts where the one before ended.
        for (before, after) in zip(stretches, stretches.dropFirst()) {
            #expect(before.points.last == after.points.first)
        }
        #expect(stretches.first?.points.first == line.first)
        #expect(stretches.last?.points.last == line.last)
    }

    @Test func oneStretchWithoutChanges() {
        let stretches = TrackSpeeds.stretches(along: line) { _ in 250 }
        #expect(stretches.count == 1)
        #expect(stretches[0].band == 250)
    }

    @Test func unknownEverywhere() {
        let stretches = TrackSpeeds.stretches(along: line) { _ in nil }
        #expect(stretches.map(\.band) == [nil])
        #expect(TrackSpeeds.stretches(along: [line[0]]) { _ in 100 }.isEmpty)
    }
}
