import Foundation
import Observation
import ZugbarCore

/// The search for a connection at the destination, in the destination card.
@MainActor
@Observable
final class ConnectionSearch {
    /// What a search needs from the trip: where the user gets off, and the ICE portal when on board.
    struct Context {
        var destination: Stop?
        var portal: ICEPortal?
        var now: Date
    }

    /// Collapsed until the user asks for it.
    var isAdding = false {
        didSet { if isAdding { loadPortalConnections() } else if oldValue { reset() } }
    }
    var query = "" {
        didSet { queryChanged() }
    }
    private(set) var targets: [TransitousClient.Station] = []
    private(set) var options: [Connection] = []
    private(set) var message: PickerMessage?
    /// Connections the ICE portal lists for the destination; empty when not on an ICE.
    private(set) var portalConnections: [Connection] = []

    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var target: TransitousClient.Station?
    private let client: TransitousClient
    private let context: () -> Context

    init(client: TransitousClient, context: @escaping () -> Context) {
        self.client = client
        self.context = context
    }

    func loadPortalConnections() {
        portalConnections = []
        let context = context()
        guard let portal = context.portal, let destination = context.destination else { return }
        Task {
            let connections = (try? await portal.connections(at: destination)) ?? []
            portalConnections = connections.filter { ($0.departure ?? .distantFuture) >= (destination.arrival ?? context.now) }
        }
    }

    func choose(_ target: TransitousClient.Station) {
        let context = context()
        guard let destination = context.destination else { return }
        search?.cancel()
        targets = []
        self.target = target
        query = target.name
        message = .loadingDepartures
        let regional = UserDefaults.standard.object(forKey: "regionalTrains") as? Bool ?? true
        // Stored so choosing another target or closing the picker cancels this search.
        search = Task {
            do {
                guard let station = try await client.stations(matching: destination.name).first else {
                    if !Task.isCancelled { message = .noStation }
                    return
                }
                let found = try await client.connections(
                    from: station, to: target, after: destination.arrival ?? context.now, regional: regional
                )
                guard !Task.isCancelled else { return }
                options = found.map { option in
                    var option = option
                    option.station = destination.name
                    return option
                }
                message = found.isEmpty ? (regional ? .noDirectConnection : .regionalOff) : nil
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

    func reset() {
        search?.cancel()
        targets = []
        options = []
        message = nil
        target = nil
        query = ""
    }

    private func queryChanged() {
        if let target, target.name == query { return }
        target = nil
        search?.cancel()
        options = []
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            targets = []
            return
        }
        search = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let found = try? await client.stations(matching: text), !Task.isCancelled else { return }
            targets = found
            message = found.isEmpty ? .noStation : nil
        }
    }
}
