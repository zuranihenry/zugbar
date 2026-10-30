import Foundation
import Observation
import ZugbarCore

/// DB's coach sequences for the trains and stops the user entered a coach for, so the cards can say which platform
/// sector it stops in. Asked for sparingly, see `CoachSequencePolicy`.
@MainActor
@Observable
final class CoachSectors {
    /// A train leaving a stop, as the cards know it. The platform is part of it: after a platform change the
    /// coaches stop in other sectors, so that's asked for again.
    struct Spot: Hashable {
        let train: String
        let stop: String
        let departure: Date
        let platform: String?

        init(train: String, stop: String, departure: Date, track: String?) {
            self.train = train
            self.stop = stop
            self.departure = departure
            platform = CoachSequence.platform(track)
        }
    }

    private(set) var sequences: [Spot: CoachSequence] = [:]
    @ObservationIgnored private var policy = CoachSequencePolicy<Spot>()
    @ObservationIgnored private var loading = false
    /// DB station numbers by stop name and train category, which don't change.
    @ObservationIgnored private var stations: [String: String] = [:]
    private let client: CoachSequenceClient

    init(client: CoachSequenceClient = CoachSequenceClient()) {
        self.client = client
    }

    /// The coach sequence of `train` leaving `stop` at `departure` from `track`, once it's been loaded.
    /// Nil while DB still has it on another platform.
    func sequence(train: String, at stop: Stop, departure: Date?, track: String?) -> CoachSequence? {
        departure.flatMap { sequences[Spot(train: train, stop: stop.name, departure: $0, track: track)] }
            .flatMap { $0.fits(track: track) ? $0 : nil }
    }

    /// Asks for the coach sequence of `train` leaving `stop` at its planned `departure` from `track`, when the policy
    /// allows. A train's last stop has no departure, and no coach sequence either.
    func load(train: String, at stop: Stop, departure: Date?, track: String?, now: Date) {
        guard !loading, let departure, let category = TrainStatus(provider: "", trainName: train).trainNumber?.category
        else { return }
        let spot = Spot(train: train, stop: stop.name, departure: departure, track: track)
        guard policy.mayAsk(spot, departure: departure, now: now) else { return }
        loading = true
        // Earlier trains are no use any more.
        for old in sequences.keys where old.departure < now.addingTimeInterval(-60 * 60) { sequences[old] = nil }
        Task {
            defer { loading = false }
            do {
                guard let station = try await stationNumber(for: stop, category: category),
                      let query = CoachSequenceClient.Query(trainName: train, station: station, departure: departure),
                      let sequence = try await client.sequence(query)
                else { return }
                sequences[spot] = sequence
            } catch {
                policy.failed(error, now: Date())
            }
        }
    }

    private func stationNumber(for stop: Stop, category: String) async throws -> String? {
        let key = stop.name + "|" + category
        if let known = stations[key] { return known }
        let number = try await client.stationNumber(for: stop, category: category)
        stations[key] = number
        return number
    }
}

/// The coach being entered in one of the cards, one at a time.
@MainActor
@Observable
final class SeatEditor {
    enum Field: Equatable {
        case boarding, destination, connection
    }

    var editing: Field?
    var coach = ""
    var number = ""

    func edit(_ field: Field, seat: Seat?) {
        coach = seat?.coach ?? ""
        number = seat?.number ?? ""
        editing = field
    }
}
