import Foundation
import Observation
import ZugbarCore

/// The search for a connection at the destination, in the destination card.
@MainActor
@Observable
final class ConnectionSearch {
    /// What a search needs from the trip: where the user gets off.
    struct Context {
        var destination: Stop?
        var now: Date
    }

    /// Collapsed until the user asks for it.
    var isAdding = false {
        didSet { if oldValue, !isAdding { reset() } }
    }
    var query = "" {
        didSet { queryChanged() }
    }
    private(set) var targets: [TransitousClient.Station] = []
    /// Ways on from the destination, each the trains to take in order.
    private(set) var options: [[Connection]] = []
    /// Whether later ones can be asked for: the last search found some.
    private(set) var hasLater = false
    private(set) var message: PickerMessage?

    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var target: TransitousClient.Station?
    private let client: TransitousClient
    private let context: () -> Context

    init(client: TransitousClient, context: @escaping () -> Context) {
        self.client = client
        self.context = context
    }

    func choose(_ target: TransitousClient.Station) {
        targets = []
        self.target = target
        query = target.name
        options = []
        load(target, after: nil)
    }

    /// More ways to the same place, leaving after the last one listed.
    func loadLater() {
        guard let target, let last = options.last?.first?.departure else { return }
        load(target, after: last.addingTimeInterval(60))
    }

    /// `after`: nil for the first ways on after the train gets in; else later ones, added to the list.
    private func load(_ target: TransitousClient.Station, after: Date?) {
        let context = context()
        guard let destination = context.destination else { return }
        search?.cancel()
        message = .loadingDepartures
        hasLater = false
        // The time the user wants for a change counts for the first one too, off the followed train.
        let minTransfer = UserDefaults.standard.integer(forKey: "minTransferMinutes")
        let earliest = after ?? (destination.arrival ?? context.now).addingTimeInterval(Double(minTransfer) * 60)
        let regional = UserDefaults.standard.object(forKey: "regionalTrains") as? Bool ?? true
        // Stored so choosing another target or closing the picker cancels this search.
        search = Task {
            do {
                guard let station = try await client.stations(matching: destination.name).first else {
                    if !Task.isCancelled { message = .noStation }
                    return
                }
                let found = try await client.routes(
                    from: station, to: target, after: earliest, regional: regional,
                    changes: TransitousClient.maxTransfers, minTransfer: minTransfer
                ).map { route in
                    // The first train leaves where the followed one arrives, named as that one names it.
                    var route = route
                    route[0].station = destination.name
                    return route
                }
                guard !Task.isCancelled else { return }
                let known = Set(options.map(Self.id))
                options += found.filter { !known.contains(Self.id($0)) }
                hasLater = !found.isEmpty
                message = options.isEmpty ? (regional ? .noConnection : .regionalOff) : nil
            } catch {
                guard !Task.isCancelled else { return }
                message = .failed
            }
        }
    }

    /// Turns on regional trains and searches the same target again.
    func enableRegionalAndRetry() {
        UserDefaults.standard.set(true, forKey: "regionalTrains")
        if let target { choose(target) }
    }

    /// Tells two ways apart: the trips taken, in order.
    static func id(_ route: [Connection]) -> String { route.map(\.tripID).joined(separator: "|") }

    func reset() {
        search?.cancel()
        targets = []
        options = []
        hasLater = false
        message = nil
        target = nil
        query = ""
    }

    private func queryChanged() {
        if let target, target.name == query { return }
        target = nil
        search?.cancel()
        options = []
        hasLater = false
        // A message from the last search or departures lookup doesn't belong to the new text.
        message = nil
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            targets = []
            return
        }
        search = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let found = try await client.stations(matching: text)
                guard !Task.isCancelled else { return }
                targets = found
                message = found.isEmpty ? .noStation : nil
            } catch {
                guard !Task.isCancelled else { return }
                // Otherwise Enter would pick a station from an earlier query.
                targets = []
                message = .failed
            }
        }
    }
}
