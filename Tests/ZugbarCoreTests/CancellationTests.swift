import Foundation
import Testing
@testable import ZugbarCore

struct CancellationTests {
    let t0 = utc("2026-06-12T16:00:00Z")
    var t1: Date { t0.addingTimeInterval(60) }

    /// Mannheim → Frankfurt → Kassel, with the Frankfurt stop cancelled when `frankfurtCancelled` is set.
    func trip(frankfurtCancelled: Bool, tripCancelled: Bool = false) -> Data {
        Data("""
        {"legs":[{"mode":"HIGHSPEED_RAIL","displayName":"ICE 1","cancelled":\(tripCancelled),
          "from":{"name":"Mannheim Hbf","stopId":"ma","departure":"2026-06-12T16:30:00Z","scheduledDeparture":"2026-06-12T16:30:00Z"},
          "intermediateStops":[{"name":"Frankfurt (Main) Hbf","stopId":"ffm","cancelled":\(frankfurtCancelled),
            "arrival":"2026-06-12T17:10:00Z","scheduledArrival":"2026-06-12T17:10:00Z",
            "departure":"2026-06-12T17:15:00Z","scheduledDeparture":"2026-06-12T17:15:00Z","track":"7"}],
          "to":{"name":"Kassel-Wilhelmshöhe","stopId":"ks","arrival":"2026-06-12T18:30:00Z","scheduledArrival":"2026-06-12T18:30:00Z"}}]}
        """.utf8)
    }

    @Test func parsesCancelledStops() throws {
        let status = try Transitous.parse(trip: trip(frankfurtCancelled: true), now: t0)
        #expect(status.stops.map(\.cancelled) == [false, true, false])
        let whole = try Transitous.parse(trip: trip(frankfurtCancelled: false, tripCancelled: true), now: t0)
        #expect(whole.stops.filter { !$0.cancelled }.isEmpty)
    }

    @Test func nextStopSkipsCancelledStops() throws {
        let status = try Transitous.parse(trip: trip(frankfurtCancelled: true), now: t0.addingTimeInterval(45 * 60))
        #expect(status.nextStop?.name == "Kassel-Wilhelmshöhe")
    }

    @Test func refreshPicksUpCancelledConnection() async throws {
        let data = trip(frankfurtCancelled: true)
        let client = TransitousClient(loader: { _ in data })
        let connection = Connection(tripID: "x", name: "ICE 1", headsign: nil, station: "Frankfurt (Main) Hbf",
                                    scheduledDeparture: utc("2026-06-12T17:15:00Z"), expectedDeparture: nil, track: "7")
        let refreshed = try await client.refresh(connection)
        #expect(refreshed.cancelled)
        #expect(refreshed.transfer(after: t0) == .cancelled)
    }

    @Test func destinationCancelledNotifiesOnce() throws {
        let old = try Transitous.parse(trip: trip(frankfurtCancelled: false), now: t0)
        let new = try Transitous.parse(trip: trip(frankfurtCancelled: true), now: t1)
        let destination = try #require(old.stops.first { $0.name == "Frankfurt (Main) Hbf" })
        let plan = JourneyPlan(trainName: "ICE 1", destinationStopID: destination.id)
        let first = JourneyWatcher.events(old: old, oldTime: t0, oldConnection: nil, new: new, newTime: t1, newConnection: nil, plan: plan)
        #expect(first == [.stopCancelled(stop: "Frankfurt (Main) Hbf")])
        let again = JourneyWatcher.events(old: new, oldTime: t0, oldConnection: nil, new: new, newTime: t1, newConnection: nil, plan: plan)
        #expect(again.isEmpty)
    }
}

struct DepartureReminderTests {
    let t0 = utc("2026-06-12T16:00:00Z")

    func status(departureIn minutes: Double, now: Date) -> TrainStatus {
        let departure = now.addingTimeInterval(minutes * 60)
        let stop = Stop(id: "ffm", name: "Frankfurt (Main) Hbf", scheduledDeparture: departure, expectedDeparture: departure, track: "7")
        return TrainStatus(provider: "Transitous", trainName: "ICE 503", stops: [stop])
    }

    @Test func remindsBeforeDeparture() {
        let plan = JourneyPlan(trainName: "ICE 503", boardingStopID: "ffm")
        let t1 = t0.addingTimeInterval(60)
        let crossing = JourneyWatcher.events(old: status(departureIn: 10.5, now: t0), oldTime: t0, oldConnection: nil,
                                             new: status(departureIn: 9.5, now: t1), newTime: t1, newConnection: nil, plan: plan)
        #expect(crossing == [.departingSoon(stop: "Frankfurt (Main) Hbf", minutes: 10, track: "7")])
        let later = JourneyWatcher.events(old: status(departureIn: 9.5, now: t0), oldTime: t0, oldConnection: nil,
                                          new: status(departureIn: 8.5, now: t1), newTime: t1, newConnection: nil, plan: plan)
        #expect(later.isEmpty)
    }

    @Test func oldSettingsKeepTheirValues() throws {
        let saved = Data(#"{"arrivalReminders":[30],"delayThreshold":5,"trackChanges":false,"connectionAlerts":true}"#.utf8)
        let settings = try JSONDecoder().decode(NotificationSettings.self, from: saved)
        #expect(settings.arrivalReminders == [30])
        #expect(settings.delayThreshold == 5)
        #expect(!settings.trackChanges)
        #expect(settings.departureReminders == NotificationSettings().departureReminders)
    }
}

struct UpdateTests {
    @Test func comparesVersions() {
        #expect(Release.isVersion("1.10.0", newerThan: "1.9.2"))
        #expect(Release.isVersion("1.1.3", newerThan: "1.1.2"))
        #expect(Release.isVersion("2", newerThan: "1.9"))
        #expect(!Release.isVersion("1.1.2", newerThan: "1.1.2"))
        #expect(!Release.isVersion("1.1", newerThan: "1.1.0"))
        #expect(!Release.isVersion("1.0.9", newerThan: "1.1.0"))
    }

    @Test func parsesLatestRelease() throws {
        let json = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/zuranihenry/zugbar/releases/tag/v1.2.0"}"#.utf8)
        let release = try Release.parse(json)
        #expect(release.version == "1.2.0")
        #expect(release.url.absoluteString.hasSuffix("/v1.2.0"))
    }
}

struct HistoryPruningTests {
    @Test func dropsItemsUnusedForNinetyDays() {
        var history = TrainHistory()
        let start = utc("2026-01-01T08:00:00Z")
        history.record(.train("ICE 1"), at: start)
        history.record(.train("ICE 2"), at: start.addingTimeInterval(100 * 86_400))
        #expect(history.suggestions(at: start.addingTimeInterval(100 * 86_400)) == [.train("ICE 2")])
        #expect(history == {
            var expected = TrainHistory()
            expected.record(.train("ICE 2"), at: start.addingTimeInterval(100 * 86_400))
            return expected
        }())
    }
}

struct EstimatedMenuTitleTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func showsEstimateOnlyWithoutLiveSpeed() {
        let stop = Stop(id: "a", name: "Lorraine TGV", expectedArrival: now.addingTimeInterval(402))
        let status = TrainStatus(provider: "Transitous", stops: [stop], nextStopID: "a")
        let title = { (live: Int?, options: MenuTitleOptions) in
            MenuTitle.make(status: status, displaySpeed: live, isTopSpeed: false, now: now, options: options, estimatedSpeed: 287)
        }
        #expect(title(nil, .init()) == "≈ 287 km/h · → Lorraine TGV 6:42")
        #expect(title(250, .init()) == "250 km/h · → Lorraine TGV 6:42")
        #expect(title(nil, .init(showEstimate: false)) == "→ Lorraine TGV 6:42")
        #expect(title(nil, .init(showSpeed: false)) == "→ Lorraine TGV 6:42")
    }
}
