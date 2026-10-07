import Foundation
import Testing
@testable import ZugbarCore

struct JourneyTests {
    let t0 = utc("2026-06-12T16:00:00Z")
    var t1: Date { t0.addingTimeInterval(60) }

    func status(arrivalDelay: Int, track: String = "8", arrivalIn minutes: Double = 20, now: Date) -> TrainStatus {
        let scheduled = now.addingTimeInterval(minutes * 60 - Double(arrivalDelay) * 60)
        let destination = Stop(
            id: "nbg", name: "Nürnberg Hbf",
            scheduledArrival: scheduled, expectedArrival: scheduled.addingTimeInterval(Double(arrivalDelay) * 60),
            track: track
        )
        return TrainStatus(provider: "DB", trainName: "ICE 503", stops: [destination], nextStopID: "nbg")
    }

    var plan: JourneyPlan { JourneyPlan(trainName: "ICE 503", destinationStopID: "nbg") }

    func events(_ old: TrainStatus, _ new: TrainStatus, _ oldConnection: Connection? = nil, _ newConnection: Connection? = nil) -> [JourneyEvent] {
        JourneyWatcher.events(old: old, oldTime: t0, oldConnection: oldConnection,
                              new: new, newTime: t1, newConnection: newConnection, plan: plan)
    }

    @Test func delayAndTrackChanges() {
        let changes = events(status(arrivalDelay: 2, now: t0), status(arrivalDelay: 7, track: "9", arrivalIn: 24, now: t1))
        #expect(changes.contains(.delayChanged(stop: "Nürnberg Hbf", from: 2, to: 7)))
        #expect(changes.contains(.trackChanged(stop: "Nürnberg Hbf", from: "8", to: "9")))
    }

    @Test func smallDelayChangesAreIgnored() {
        #expect(events(status(arrivalDelay: 2, now: t0), status(arrivalDelay: 3, arrivalIn: 20, now: t1)).isEmpty)
    }

    @Test func arrivingSoonFiresOnce() {
        let crossing = events(status(arrivalDelay: 0, arrivalIn: 5.5, now: t0), status(arrivalDelay: 0, arrivalIn: 4.5, now: t1))
        #expect(crossing == [.arrivingSoon(stop: "Nürnberg Hbf", minutes: 5, track: "8")])
        #expect(events(status(arrivalDelay: 0, arrivalIn: 4.5, now: t0), status(arrivalDelay: 0, arrivalIn: 3.5, now: t1)).isEmpty)
    }

    @Test func transferGetsTight() {
        let old = status(arrivalDelay: 0, arrivalIn: 20, now: t0)
        let new = status(arrivalDelay: 6, arrivalIn: 25, now: t1)
        let arrival = old.stops[0].scheduledArrival!
        let connection = Connection(tripID: "re5", name: "RE 5", headsign: nil, station: "Nürnberg Hbf",
                                    scheduledDeparture: arrival.addingTimeInterval(8 * 60), expectedDeparture: arrival.addingTimeInterval(8 * 60), track: "4")
        #expect(connection.transfer(after: arrival) == .comfortable(minutes: 8))
        let changes = events(old, new, connection, connection)
        #expect(changes.contains(.transferChanged(name: "RE 5", .tight(minutes: 2))))
    }

    @Test func connectionCancelled() {
        let old = status(arrivalDelay: 0, now: t0), new = status(arrivalDelay: 0, arrivalIn: 19, now: t1)
        var connection = Connection(tripID: "re5", name: "RE 5", headsign: nil, station: "Nürnberg Hbf",
                                    scheduledDeparture: t0.addingTimeInterval(3600), expectedDeparture: nil, track: "4")
        let before = connection
        connection.cancelled = true
        #expect(events(old, new, before, connection).contains(.transferChanged(name: "RE 5", .cancelled)))
    }

    @Test func boardingStopDepartureDelay() {
        let start = { (delay: Int) -> TrainStatus in
            let scheduled = utc("2026-06-12T16:30:00Z")
            let stop = Stop(id: "ffm", name: "Frankfurt (Main) Hbf", scheduledDeparture: scheduled,
                            expectedDeparture: scheduled.addingTimeInterval(Double(delay) * 60), track: "7")
            return TrainStatus(provider: "Transitous", trainName: "ICE 503", stops: [stop])
        }
        let plan = JourneyPlan(trainName: "ICE 503", boardingStopID: "ffm")
        let changes = JourneyWatcher.events(old: start(0), oldTime: t0, oldConnection: nil,
                                            new: start(10), newTime: t1, newConnection: nil, plan: plan)
        #expect(changes == [.delayChanged(stop: "Frankfurt (Main) Hbf", from: 0, to: 10)])
    }

    @Test func delayReasonsFromICEPortal() throws {
        var json = try JSONSerialization.jsonObject(with: DemoProvider.resource("demo_db_trip")) as! [String: Any]
        var trip = json["trip"] as! [String: Any]
        var stops = trip["stops"] as! [[String: Any]]
        stops[4]["delayReasons"] = [["code": "38", "text": "Reparatur am Zug"]]
        trip["stops"] = stops
        json["trip"] = trip
        let status = try ICEPortal.parse(status: DemoProvider.resource("demo_db_status"), trip: JSONSerialization.data(withJSONObject: json))
        #expect(status.nextStop?.delayReasons == ["Reparatur am Zug"])
    }

    @Test func parsesDirectConnections() throws {
        let options = try TransitousClient.parseConnections(fixture("transitous_plan"), station: "Hannover Hbf")
        #expect(options.count == 3)
        let first = try #require(options.first)
        #expect(first.name == "S2")
        #expect(first.station == "Hannover Hbf")
        #expect(first.finalStop == "Wunstorf")
        #expect(first.track == "2")
        #expect(first.finalArrival != nil)
    }
}

struct JourneySettingsTests {
    let t0 = utc("2026-06-12T16:00:00Z")

    func status(arrivalIn minutes: Double, now: Date, delay: Int = 0, track: String = "8") -> TrainStatus {
        let scheduled = now.addingTimeInterval(minutes * 60 - Double(delay) * 60)
        let stop = Stop(id: "nbg", name: "Nürnberg Hbf", scheduledArrival: scheduled,
                        expectedArrival: scheduled.addingTimeInterval(Double(delay) * 60), track: track)
        return TrainStatus(provider: "DB", trainName: "ICE 503", stops: [stop])
    }

    func events(_ old: TrainStatus, _ new: TrainStatus, _ settings: NotificationSettings) -> [JourneyEvent] {
        JourneyWatcher.events(old: old, oldTime: t0, oldConnection: nil, new: new, newTime: t0.addingTimeInterval(60),
                              newConnection: nil, plan: JourneyPlan(trainName: "ICE 503", destinationStopID: "nbg"), settings: settings)
    }

    @Test func everyChosenReminderFires() {
        var settings = NotificationSettings()
        settings.arrivalReminders = [15, 5]
        #expect(events(status(arrivalIn: 15.5, now: t0), status(arrivalIn: 14.5, now: t0.addingTimeInterval(60)), settings)
            == [.arrivingSoon(stop: "Nürnberg Hbf", minutes: 15, track: "8")])
        #expect(events(status(arrivalIn: 5.5, now: t0), status(arrivalIn: 4.5, now: t0.addingTimeInterval(60)), settings)
            == [.arrivingSoon(stop: "Nürnberg Hbf", minutes: 5, track: "8")])
        #expect(events(status(arrivalIn: 10.5, now: t0), status(arrivalIn: 9.5, now: t0.addingTimeInterval(60)), settings).isEmpty)
    }

    @Test func thresholdsAndToggles() {
        var settings = NotificationSettings()
        settings.delayThreshold = 10
        settings.trackChanges = false
        let old = status(arrivalIn: 30, now: t0)
        let new = status(arrivalIn: 34, now: t0.addingTimeInterval(60), delay: 5, track: "9")
        #expect(events(old, new, settings).isEmpty)
        settings.delayThreshold = 3
        #expect(events(old, new, settings) == [.delayChanged(stop: "Nürnberg Hbf", from: 0, to: 5)])
    }
}

struct PositionTests {
    @Test func gpsFromICEPortal() throws {
        let status = try ICEPortal.parse(status: DemoProvider.resource("demo_db_status"), trip: DemoProvider.resource("demo_db_trip"))
        #expect(status.position == Coordinate(latitude: 50.08, longitude: 11.05))
        #expect(status.stops.first?.coordinate != nil)
    }

    @Test func interpolatesBetweenStops() {
        let start = utc("2026-06-12T16:00:00Z")
        let stops = [
            Stop(id: "a", name: "A", scheduledDeparture: start, passed: true, coordinate: Coordinate(latitude: 50, longitude: 10)),
            Stop(id: "b", name: "B", scheduledArrival: start.addingTimeInterval(3600), coordinate: Coordinate(latitude: 52, longitude: 12)),
        ]
        let status = TrainStatus(provider: "Transitous", stops: stops)
        #expect(status.position(at: start.addingTimeInterval(1800)) == Coordinate(latitude: 51, longitude: 11))
    }

    @Test func estimatesSpeedBetweenStops() {
        let start = utc("2026-06-12T16:00:00Z")
        // Frankfurt Hbf → Köln Hbf, ~152 km straight line, in one hour.
        let stops = [
            Stop(id: "f", name: "Frankfurt", scheduledDeparture: start, passed: true, coordinate: Coordinate(latitude: 50.1071, longitude: 8.6638)),
            Stop(id: "k", name: "Köln", scheduledArrival: start.addingTimeInterval(3600), coordinate: Coordinate(latitude: 50.9430, longitude: 6.9589)),
        ]
        let status = TrainStatus(provider: "Transitous", stops: stops)
        let speed = status.estimatedSpeed(at: start.addingTimeInterval(1200))
        #expect(speed.map { (150...175).contains($0) } == true)
        #expect(status.estimatedSpeed(at: start.addingTimeInterval(-60)) == nil)
    }

    @Test func ignoresZeroCoordinates() throws {
        let status = try SNCFInoui.parse(details: fixture("sncf_details"), gps: fixture("sncf_gps"))
        #expect(status.stops.allSatisfy { $0.coordinate == nil })
        #expect(status.position == Coordinate(latitude: 44.4, longitude: 4.8))
    }
}

struct PortalConnectionTests {
    @Test func parsesICEPortalConnections() throws {
        let json = Data(#"{"connections":[{"trainType":"RE","vzn":"1","station":{"name":"Regensburg Hbf"},"timetable":{"scheduledDepartureTime":1781283300000,"actualDepartureTime":1781283420000},"track":{"scheduled":"12","actual":"13"}}]}"#.utf8)
        let connections = try ICEPortal.parseConnections(json, station: "Nürnberg Hbf", stationID: "8000284_00", evaNr: "8000284")
        let first = try #require(connections.first)
        #expect(first.name == "RE 1")
        #expect(first.finalStop == "Regensburg Hbf")
        #expect(first.track == "13")
        #expect(first.delayMinutes == 2)
        #expect(first.portalStationID == "8000284_00")
    }
}

struct RepeatedWarningTests {
    @Test func warnsOncePerLevel() {
        let connection = Connection(tripID: "s4", name: "S4", headsign: nil, station: "Hannover Hbf",
                                    scheduledDeparture: nil, expectedDeparture: nil, track: "2")
        var plan = JourneyPlan(trainName: "ICE 619", destinationStopID: "h", connection: connection)
        let tight: [JourneyEvent] = [.transferChanged(name: "S4", .tight(minutes: 3))]
        #expect(plan.withoutRepeatedWarnings(tight).count == 1)
        // Swinging back to comfortable and tight again stays quiet.
        #expect(plan.withoutRepeatedWarnings(tight).isEmpty)
        // Getting worse still notifies.
        #expect(plan.withoutRepeatedWarnings([.transferChanged(name: "S4", .atRisk(minutes: 1))]).count == 1)
        // Other events are untouched.
        #expect(plan.withoutRepeatedWarnings([.trackChanged(stop: "Hannover Hbf", from: "7", to: "8")]).count == 1)
        // A new connection starts over.
        plan.connection = Connection(tripID: "s5", name: "S5", headsign: nil, station: "Hannover Hbf",
                                     scheduledDeparture: nil, expectedDeparture: nil, track: "2")
        #expect(plan.withoutRepeatedWarnings([.transferChanged(name: "S5", .tight(minutes: 3))]).count == 1)
    }

    @Test func survivesSaving() throws {
        var plan = JourneyPlan(trainName: "ICE 619", connection: Connection(tripID: "s4", name: "S4", headsign: nil,
            station: "Hannover Hbf", scheduledDeparture: nil, expectedDeparture: nil, track: nil))
        _ = plan.withoutRepeatedWarnings([.transferChanged(name: "S4", .tight(minutes: 3))])
        var restored = try JSONDecoder().decode(JourneyPlan.self, from: JSONEncoder().encode(plan))
        #expect(restored.withoutRepeatedWarnings([.transferChanged(name: "S4", .tight(minutes: 4))]).isEmpty)
    }

    @Test func loadsPlansFromOlderVersions() throws {
        let old = Data(#"{"trainName":"ICE 619","destinationStopID":"h"}"#.utf8)
        let plan = try JSONDecoder().decode(JourneyPlan.self, from: old)
        #expect(plan.destinationStopID == "h")
    }
}
