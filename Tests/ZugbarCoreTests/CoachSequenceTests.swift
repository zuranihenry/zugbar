import Foundation
import Testing
@testable import ZugbarCore

struct CoachSequenceTests {
    @Test func parsesCoupledTrains() throws {
        let sequence = try CoachSequenceClient.parse(fixture("bahn_coach_sequence"))
        #expect(sequence.track == "7")
        // The locomotive at the end has no number and isn't listed.
        #expect(sequence.coaches.map(\.number) == ["39", "38", "37", "36", "35", "21", "22", "23", "26"])
        #expect(sequence.coach("37")?.sector == "B")
        #expect(sequence.coach("23")?.sector == "E")
        #expect(sequence.coach("36")?.closed == true)
        #expect(sequence.coach("35")?.closed == false)
        #expect(sequence.coach("24") == nil)
    }

    @Test func matchesCoachesAsTyped() {
        let sequence = CoachSequence(track: nil, coaches: [.init(number: "8", sector: "C"), .init(number: "10", sector: "D")])
        #expect(sequence.coach("08")?.sector == "C")
        #expect(sequence.coach(" 8 ")?.sector == "C")
        #expect(sequence.coach("10")?.sector == "D")
        #expect(sequence.coach("1") == nil)
    }

    @Test func sectorsAreForOnePlatform() {
        let sequence = CoachSequence(track: "7", coaches: [.init(number: "8", sector: "C")])
        #expect(sequence.fits(track: "7"))
        // Written differently by another source, still the same platform.
        #expect(sequence.fits(track: "7 D-G"))
        #expect(sequence.fits(track: "07"))
        // Unknown on either side: nothing to go by.
        #expect(sequence.fits(track: nil))
        #expect(CoachSequence(track: nil, coaches: []).fits(track: "9"))
        // After a platform change the sectors are the old platform's.
        #expect(!sequence.fits(track: "9"))
        #expect(!sequence.fits(track: "17"))
        #expect(CoachSequence.platform("Gl. A") == "Gl. A")
        #expect(CoachSequence.platform(" ") == nil)
    }

    @Test func longDistanceTrainsNumberTheirCoaches() {
        #expect(CoachSequence.numbersCoaches("ICE 999"))
        #expect(CoachSequence.numbersCoaches("IC 998"))
        #expect(CoachSequence.numbersCoaches("RJX 997"))
        #expect(!CoachSequence.numbersCoaches("RE80 (4711)"))
        #expect(!CoachSequence.numbersCoaches("S8"))
        #expect(!CoachSequence.numbersCoaches(nil))
    }

    @Test func asksForTheDepartureInUTC() throws {
        let query = try #require(CoachSequenceClient.Query(trainName: "ICE 999", station: "8099901", departure: utc("2026-06-15T23:30:00Z")))
        let url = CoachSequenceClient.url(for: query)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        #expect(url.path() == "/web/api/reisebegleitung/wagenreihung/vehicle-sequence")
        #expect(value("category") == "ICE")
        #expect(value("number") == "999")
        #expect(value("evaNumber") == "8099901")
        #expect(value("date") == "2026-06-15")
        #expect(value("time") == "2026-06-15T23:30:00.000Z")
        #expect(value("administrationId") == "80")

        #expect(CoachSequenceClient.Query(trainName: "RE80 (4711)", station: "8099901", departure: Date())?.number == "4711")
        #expect(CoachSequenceClient.Query(trainName: "S8", station: "8099901", departure: Date()) == nil)
    }

    @Test func noSequenceIsNotAnError() async throws {
        let client = CoachSequenceClient { _ in throw ProviderError.badStatus(404) }
        let query = CoachSequenceClient.Query(category: "ICE", number: "999", station: "8099901", departure: Date())
        #expect(try await client.sequence(query) == nil)
        let failing = CoachSequenceClient { _ in throw ProviderError.badStatus(503) }
        await #expect(throws: ProviderError.badStatus(503)) { try await failing.sequence(query) }
    }

    @Test func findsStationNumbers() async throws {
        #expect(CoachSequenceClient.stationNumber(inStopID: "8099901_00") == "8099901")
        #expect(CoachSequenceClient.stationNumber(inStopID: "8199901") == "8199901")
        #expect(CoachSequenceClient.stationNumber(inStopID: "3-de-DELFI_de:99999:1:2:3") == nil)
        #expect(CoachSequenceClient.stationNumber(inStopID: "FRXYZ") == nil)

        // The S-Bahn station underneath is nearer, but an ICE stops at the main station.
        let nearby = try fixture("bahn_nearby")
        #expect(try CoachSequenceClient.parseNearby(nearby, category: "ICE") == "8099901")
        #expect(try CoachSequenceClient.parseNearby(nearby, category: "S") == "8099902")
        #expect(try CoachSequenceClient.parseNearby(Data("[]".utf8), category: "ICE") == nil)

        let online = Stop(id: "4-de-DELFI_de:99999:1:2:3", name: "Musterstadt Hbf", coordinate: Coordinate(latitude: 50, longitude: 8))
        let client = CoachSequenceClient { url in
            #expect(url.path() == "/web/api/reiseloesung/orte/nearby")
            return nearby
        }
        #expect(try await client.stationNumber(for: online, category: "IC") == "8099901")
        #expect(try await client.stationNumber(for: Stop(id: "8099903_00", name: "Beispielhausen"), category: "IC") == "8099903")
        #expect(try await client.stationNumber(for: Stop(id: "x", name: "Nowhere"), category: "IC") == nil)
    }

    @Test func plansSavedWithoutSeatsStillLoad() throws {
        let old = #"{"trainName":"ICE 999","destinationStopID":"8099901_00","connection":{"tripID":"t","name":"IC 998","station":"Musterstadt Hbf","cancelled":false}}"#
        let plan = try JSONDecoder().decode(JourneyPlan.self, from: Data(old.utf8))
        #expect(plan.seat == nil)
        #expect(plan.connection?.seat == nil)

        var updated = plan
        updated.seat = Seat(coach: "8", number: "42")
        updated.connection?.seat = Seat(coach: "3")
        let decoded = try JSONDecoder().decode(JourneyPlan.self, from: JSONEncoder().encode(updated))
        #expect(decoded == updated)
    }

    @Test func seatsFromTypedText() {
        #expect(Seat(typedCoach: " 8 ", seat: "") == Seat(coach: "8"))
        #expect(Seat(typedCoach: "8", seat: " 42 ") == Seat(coach: "8", number: "42"))
        #expect(Seat(typedCoach: "  ", seat: "42") == nil)
    }

    @Test func connectionSeatMovesToTheNextPlan() {
        var connection = Connection(tripID: "t", name: "IC 998", headsign: nil, station: "Musterstadt Hbf",
                                    scheduledDeparture: nil, expectedDeparture: nil, track: nil)
        connection.seat = Seat(coach: "3", number: "15")
        #expect(Handover.plan(after: connection).seat == Seat(coach: "3", number: "15"))
    }
}

struct CoachSequencePolicyTests {
    let departure = utc("2026-06-15T18:00:00Z")

    /// Whether `policy` lets `key` ask `minutes` after 90 minutes before departure.
    private func ask(_ policy: inout CoachSequencePolicy<String>, _ key: String, after minutes: Double) -> Bool {
        policy.mayAsk(key, departure: departure, now: departure.addingTimeInterval((minutes - 90) * 60))
    }

    @Test func asksFromTwoHoursBeforeDeparture() {
        var policy = CoachSequencePolicy<String>()
        let early = ask(&policy, "a", after: -90)
        let inTime = ask(&policy, "a", after: 0)
        #expect(!early)
        #expect(inTime)
        var late = CoachSequencePolicy<String>()
        let afterDeparture = ask(&late, "a", after: 105)
        #expect(!afterDeparture)
    }

    @Test func spacesRequestsOut() {
        var policy = CoachSequencePolicy<String>()
        let first = ask(&policy, "a", after: 0)
        // Another train or stop, but too soon after the last request.
        let tooSoon = ask(&policy, "b", after: 0.5)
        let aMinuteLater = ask(&policy, "b", after: 1)
        // The same one again only after half an hour.
        let again = ask(&policy, "a", after: 20)
        let halfAnHourLater = ask(&policy, "a", after: 30)
        #expect([first, tooSoon, aMinuteLater, again, halfAnHourLater] == [true, false, true, false, true])
    }

    @Test func pausesAfterARefusal() {
        var policy = CoachSequencePolicy<String>()
        let start = departure.addingTimeInterval(-90 * 60)
        policy.failed(ProviderError.badStatus(404), now: start)
        policy.failed(URLError(.timedOut), now: start)
        let afterOtherErrors = ask(&policy, "a", after: 0)
        #expect(afterOtherErrors)

        policy.failed(ProviderError.badStatus(403), now: start)
        let refused = ask(&policy, "b", after: 60)
        #expect(!refused)
        let later = departure.addingTimeInterval(6 * 60 * 60)
        let afterPause = policy.mayAsk("c", departure: later.addingTimeInterval(60 * 60), now: later)
        #expect(afterPause)
    }
}
