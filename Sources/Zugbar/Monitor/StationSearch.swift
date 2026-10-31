import Foundation
import Observation
import ZugbarCore

/// What a station or connection search shows instead of results.
enum PickerMessage: Equatable {
    case noStation, loadingDepartures, noDepartures, failed
    /// No direct connection; `regionalOff` means only long-distance trains were searched.
    case noDirectConnection, regionalOff
}

/// Finding a train when not on board: a station's departures for regional trains, and the trains running right now.
@MainActor
@Observable
final class StationSearch {
    var query = "" {
        didSet { queryChanged() }
    }
    var selectedLine: String?
    private(set) var stations: [TransitousClient.Station] = []
    private(set) var selectedStation: TransitousClient.Station?
    private(set) var departures: [TransitousClient.Departure] = []
    private(set) var message: PickerMessage?
    private(set) var liveTrains: [LiveTrain] = []

    @ObservationIgnored private var liveTrainsLoaded: Date?
    @ObservationIgnored private var liveTrainsLoading = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private let client: TransitousClient
    /// Whether the picker is on screen, i.e. no train is followed; departures stop reloading otherwise.
    private let isShown: () -> Bool

    init(client: TransitousClient, isShown: @escaping () -> Bool) {
        self.client = client
        self.isShown = isShown
    }

    var filteredDepartures: [TransitousClient.Departure] {
        guard let selectedLine else { return departures }
        return departures.filter { $0.line == selectedLine }
    }

    var lines: [String] { TransitousClient.lines(in: departures) }

    /// The train that most recently left: if you just boarded, it's probably this one.
    func likelyDeparture(at now: Date) -> TransitousClient.Departure? {
        filteredDepartures.last { departure in
            guard let time = departure.time, !departure.cancelled else { return false }
            return time <= now && time > now.addingTimeInterval(-30 * 60)
        }
    }

    /// Refreshes the "live right now" list at most every five minutes.
    func loadLiveTrains() {
        if let loaded = liveTrainsLoaded, Date().timeIntervalSince(loaded) < 300 { return }
        // A map of every moving train, megabytes: not on Wi-Fi with a data limit.
        guard !liveTrainsLoading, !DataSaver.shared.isOn else { return }
        liveTrainsLoading = true
        Task {
            defer { liveTrainsLoading = false }
            // Only a successful load counts, so a failed one is retried the next time the list is shown.
            guard let trains = try? await client.liveTrains() else { return }
            liveTrains = trains
            liveTrainsLoaded = Date()
        }
    }

    func choose(_ station: TransitousClient.Station, line: String? = nil) {
        searchTask?.cancel()
        selectedStation = station
        stations = []
        query = station.name
        selectedLine = line
        message = .loadingDepartures
        // Stored so picking another station or clearing it cancels this load.
        searchTask = Task {
            // Reloaded every minute for new delays, tracks and departures; for half an hour at most, since
            // Transitous is a shared service and the list may sit there unseen.
            for _ in 0..<30 where !Task.isCancelled {
                do {
                    // Start half an hour back so a train you've just boarded is still listed.
                    let found = try await client.departures(from: station, at: Date().addingTimeInterval(-30 * 60), count: 120)
                    guard !Task.isCancelled else { return }
                    departures = found
                    message = found.isEmpty ? .noDepartures : nil
                } catch {
                    guard !Task.isCancelled else { return }
                    // A failed reload keeps the list that's already there.
                    if departures.isEmpty { message = .failed }
                }
                try? await Task.sleep(for: .seconds(60))
                guard isShown(), selectedStation == station else { return }
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        selectedStation = nil
        departures = []
        stations = []
        selectedLine = nil
        message = nil
        query = ""
    }

    private func queryChanged() {
        if let selectedStation {
            guard query != selectedStation.name else { return }
            self.selectedStation = nil
            departures = []
            selectedLine = nil
        }
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            stations = []
            message = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let found = try await client.stations(matching: text)
                guard !Task.isCancelled else { return }
                stations = found
                message = found.isEmpty ? .noStation : nil
            } catch {
                guard !Task.isCancelled else { return }
                message = .failed
            }
        }
    }
}
