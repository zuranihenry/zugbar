import Foundation
import Testing
@testable import ZugbarCore

struct LiveTrainTests {
    @Test func parsesLongDistanceOnly() throws {
        let trains = try TransitousClient.parseLiveTrains(fixture("transitous_live"))
        #expect(!trains.isEmpty)
        #expect(trains.allSatisfy { $0.averageSpeed > 0 && $0.averageSpeed <= 350 })
        #expect(Set(trains.map(\.tripID)).count == trains.count)
        #expect(!trains.contains { $0.name.hasPrefix("FlixBus") })
    }

    @Test func ranking() {
        func train(_ name: String, speed: Int, delay: Int) -> LiveTrain {
            LiveTrain(tripID: name, name: name, from: "A", to: "B", averageSpeed: speed, delayMinutes: delay)
        }
        let trains = [train("ICE 1", speed: 280, delay: 0), train("IC 2", speed: 140, delay: 45), train("ICE 3", speed: 300, delay: 5)]
        #expect(LiveTrain.fastest(trains).map(\.name) == ["ICE 3", "ICE 1"])
        #expect(LiveTrain.mostDelayed(trains).map(\.name) == ["IC 2", "ICE 3"])
    }
}

struct TrainHistoryTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func date(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func timeOfDayWins() {
        var history = TrainHistory()
        let commute = TrainHistory.Item.line(stationID: "x", stationName: "Hannover Hbf", line: "S3")
        for day in 1...5 { history.record(commute, at: date(day: day, 7, 50)) }
        for day in 1...6 { history.record(.train("ICE 591"), at: date(day: day, 18, 10)) }

        #expect(history.suggestions(at: date(day: 6, 7, 40), calendar: calendar).first == commute)
        #expect(history.suggestions(at: date(day: 6, 18, 0), calendar: calendar).first == .train("ICE 591"))
    }

    @Test func forgetsOldAndRemoved() {
        var history = TrainHistory()
        history.record(.train("ICE 1"), at: date(day: 1, 9))
        history.record(.train("ICE 2"), at: date(day: 1, 9))
        history.remove(.train("ICE 2"))
        #expect(history.suggestions(at: date(day: 2, 9), calendar: calendar) == [.train("ICE 1")])

        let muchLater = date(day: 1, 9).addingTimeInterval(120 * 86_400)
        #expect(history.suggestions(at: muchLater, calendar: calendar).isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        var history = TrainHistory()
        history.record(.line(stationID: "s", stationName: "Hannover Hbf", line: "S4"))
        let decoded = try JSONDecoder().decode(TrainHistory.self, from: JSONEncoder().encode(history))
        #expect(decoded == history)
    }
}
