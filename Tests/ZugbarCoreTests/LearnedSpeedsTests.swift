import Foundation
import Testing
@testable import ZugbarCore

struct LearnedSpeedsTests {
    let town = Coordinate(latitude: 50.1210, longitude: 8.9290)

    @Test func needsTwoObservations() {
        var learned = LearnedSpeeds()
        learned.record(town, speed: 140, kind: .highSpeed)
        #expect(learned.cap(at: town, kind: .highSpeed) == nil)
        learned.record(town, speed: 155, kind: .highSpeed)
        #expect(learned.cap(at: town, kind: .highSpeed) == 160)
    }

    @Test func neighborsCountAndKindsAreSeparate() {
        var learned = LearnedSpeeds()
        learned.record(town, speed: 150, kind: .highSpeed)
        learned.record(Coordinate(latitude: town.latitude + 0.0026, longitude: town.longitude), speed: 145, kind: .highSpeed)
        #expect(learned.cap(at: town, kind: .highSpeed) == 155)
        #expect(learned.cap(at: town, kind: .regional) == nil)
        #expect(learned.cap(at: Coordinate(latitude: 51, longitude: 9), kind: .highSpeed) == nil)
    }

    @Test func ignoresStandingAndNonsense() {
        var learned = LearnedSpeeds()
        learned.record(town, speed: 5, kind: .highSpeed)
        learned.record(town, speed: 900, kind: .highSpeed)
        #expect(learned.cellCount == 0)
    }

    @Test func lowersLimitsWhereLearned() {
        var learned = LearnedSpeeds()
        let start = Coordinate(latitude: 50.10, longitude: 8.90)
        let end = Coordinate(latitude: 50.20, longitude: 9.20)
        // Observed only near the start: about 140 km/h.
        for _ in 0..<3 { learned.record(start, speed: 140, kind: .highSpeed) }
        let result = learned.apply(to: Array(repeating: 200, count: 50), along: [start, end], kind: .highSpeed)
        #expect(result.limits.first == 145)
        #expect(result.limits.last == 200)
        #expect(result.covered >= 1 && result.covered < 50)
    }

    @Test func roundTripsThroughJSON() throws {
        var learned = LearnedSpeeds()
        learned.record(town, speed: 150, kind: .regional)
        let decoded = try JSONDecoder().decode(LearnedSpeeds.self, from: JSONEncoder().encode(learned))
        #expect(decoded == learned)
    }
}
