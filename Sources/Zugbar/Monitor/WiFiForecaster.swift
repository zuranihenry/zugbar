import Foundation
import Observation
import ZugbarCore

/// The train Wi-Fi ahead, now that the ICE portal mostly sends only the current level: learned on board where it
/// was weak or gone, and forecast along the route from that. Stays on this Mac, next to the learned speeds.
@MainActor
@Observable
final class WiFiForecaster {
    private(set) var learnedCellCount = 0

    @ObservationIgnored private var learned = LearnedWiFi()
    @ObservationIgnored private var tracker = WiFiTracker()
    @ObservationIgnored private var alert = DeadZoneAlert()
    private let store = LearnedStore(file: "learned-wifi.json", empty: LearnedWiFi())

    /// The same switch as the learned speeds: "Learn from your trips".
    private var learningEnabled: Bool { UserDefaults.standard.object(forKey: "learnSpeeds") as? Bool ?? true }
    private var alertsEnabled: Bool { UserDefaults.standard.bool(forKey: "wifiAlerts") }

    /// Notes the Wi-Fi where the train is, and fills in the change ahead when the portal sent none.
    func update(_ status: TrainStatus, strings: Strings) -> TrainStatus {
        guard learningEnabled, !status.isOnline else { return status }
        let now = Date()
        let verdicts = tracker.update(status, at: now)
        if !verdicts.isEmpty {
            for verdict in verdicts { learned.record(verdict.quality, at: verdict.coordinate) }
            learnedCellCount = learned.cellCount
            let store = store
            Task { await store.update { for verdict in verdicts { $0.record(verdict.quality, at: verdict.coordinate) } } }
        }
        guard let internet = status.internet, let along = tracker.along,
              let forecast = learned.forecast(for: status, along: along, at: now)
        else { return status }
        if alertsEnabled, let zone = alert.check(forecast, current: internet.current, at: now) {
            let (title, body) = strings.wifiGap(in: zone.start.timeIntervalSince(now), lasting: zone.end.timeIntervalSince(zone.start))
            Notifier.post(title: title, body: body)
        }
        var status = status
        status.internet = forecast.filling(internet)
        return status
    }

    func load() {
        let store = store
        Task {
            learned = await store.value
            learnedCellCount = learned.cellCount
        }
    }

    func clear() {
        learned = LearnedWiFi()
        learnedCellCount = 0
        let store = store
        Task { await store.clear() }
    }
}
