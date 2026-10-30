import Foundation
import Network
import Observation
import ZugbarCore

/// Saves data where the Wi-Fi has a limit: reads the Mac's allowance from the train's router or the hotspot's
/// gateway, warns once when most of it is used, and tells the parts that download things whether to hold back.
@MainActor
@Observable
final class DataSaver {
    static let shared = DataSaver()
    static let settingKey = "dataSaving"

    private(set) var allowance: DataAllowance?
    private(set) var lowDataMode = false

    @ObservationIgnored private var checked: Date?
    @ObservationIgnored private var warning = AllowanceWarning()
    @ObservationIgnored private var router: String?
    @ObservationIgnored private var gatewayTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    private var setting: DataSaving {
        UserDefaults.standard.string(forKey: Self.settingKey).flatMap(DataSaving.init) ?? .automatic
    }

    var isOn: Bool { setting.isOn(allowance: allowance, lowDataMode: lowDataMode) }

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(lowDataMode: path.isConstrained) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// After the train's router answered: asks it for the allowance, at most once a minute. The router is on board,
    /// so asking costs none of the allowance.
    func routerAnswered(_ router: Icomera) {
        if let checked, Date().timeIntervalSince(checked) < 60 { return }
        checked = Date()
        Task {
            let found: DataAllowance?
            do { found = try await router.allowance() } catch { return }
            update(found)
        }
    }

    /// Path updates also come from lease renewals and VPNs; only another router is another network.
    private func networkChanged(lowDataMode: Bool) {
        self.lowDataMode = lowDataMode
        let router = OnboardNetwork.router
        guard router != self.router else { return }
        self.router = router
        allowance = nil
        checked = nil
        watchGateway(router)
    }

    /// Asks a hotspot gateway for the session's allowance once on joining, and every minute after if it has one.
    private func watchGateway(_ router: String?) {
        gatewayTask?.cancel()
        guard let url = router.flatMap(HotspotGateway.statusURL) else { return }
        gatewayTask = Task { [weak self] in
            var isHotspot = false
            while !Task.isCancelled {
                let found = (try? await URLSession.portal.loader(url)).flatMap(HotspotGateway.parseStatus)
                guard let self, !Task.isCancelled else { return }
                if found != nil { isHotspot = true }
                // Most networks have no such gateway: one request, then quiet.
                guard isHotspot else { return }
                update(found)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func update(_ found: DataAllowance?) {
        allowance = found
        guard let found, warning.check(found) else { return }
        let strings = Strings(AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system)
        let (title, body) = strings.allowanceWarning(found)
        Notifier.post(title: title, body: body)
    }
}
