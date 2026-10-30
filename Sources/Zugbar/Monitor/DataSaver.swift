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
    /// Only on a train does Zugbar ask a network's router about its allowance, not at home or in the office.
    @ObservationIgnored private var onTrain = false
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

    /// Whether a train is followed, on board or online; checked every second.
    func followsTrain(_ onTrain: Bool) {
        guard onTrain != self.onTrain else { return }
        self.onTrain = onTrain
        watchGateway()
    }

    /// Path updates also come from lease renewals and VPNs; only another router is another network.
    private func networkChanged(lowDataMode: Bool) {
        self.lowDataMode = lowDataMode
        let router = OnboardNetwork.router
        guard router != self.router else { return }
        self.router = router
        allowance = nil
        checked = nil
        watchGateway()
    }

    /// Asks a hotspot gateway for the session's allowance every minute. Before the login page there's no session
    /// yet, so a gateway is asked again for a while; any other router only once.
    private func watchGateway() {
        gatewayTask?.cancel()
        gatewayTask = nil
        guard onTrain, let router else { return }
        var urls = HotspotGateway.statusURLs(router: router)
        gatewayTask = Task { [weak self] in
            var isGateway = false, waited = 0
            while !Task.isCancelled {
                var data: Data?
                for url in urls {
                    data = try? await URLSession.portal.loader(url)
                    // Once one answers like a gateway, only that one.
                    if let data, HotspotGateway.isGateway(data) { urls = [url]; break }
                }
                guard let self, !Task.isCancelled else { return }
                if let found = data.flatMap(HotspotGateway.parseStatus) {
                    isGateway = true
                    update(found)
                } else if let data, HotspotGateway.isGateway(data) {
                    isGateway = true
                    waited += 1
                    if waited > 15, allowance == nil { return }
                } else if !isGateway {
                    return
                }
                // A failed read keeps what was there.
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
