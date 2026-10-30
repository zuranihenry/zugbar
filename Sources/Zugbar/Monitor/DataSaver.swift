import Foundation
import Network
import Observation
import ZugbarCore

/// Saves data where the Wi-Fi has a limit: reads the Mac's allowance from the train's router, warns once when most
/// of it is used, and tells the parts that download things whether to hold back.
@MainActor
@Observable
final class DataSaver {
    static let shared = DataSaver()
    static let settingKey = "dataSaving"

    private(set) var allowance: DataAllowance?
    private(set) var lowDataMode = false

    @ObservationIgnored private var checked: Date?
    @ObservationIgnored private var warning = AllowanceWarning()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    private var setting: DataSaving {
        UserDefaults.standard.string(forKey: Self.settingKey).flatMap(DataSaving.init) ?? .automatic
    }

    var isOn: Bool { setting.isOn(allowance: allowance, lowDataMode: lowDataMode) }

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.lowDataMode = path.isConstrained
                // Another network: the allowance was this one's.
                self.allowance = nil
                self.checked = nil
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// After the train's router answered: asks it for the allowance, at most once a minute. The router is on board,
    /// so asking costs none of the allowance.
    func routerAnswered(_ router: Icomera, strings: Strings) {
        if let checked, Date().timeIntervalSince(checked) < 60 { return }
        checked = Date()
        Task {
            let found: DataAllowance?
            do { found = try await router.allowance() } catch { return }
            allowance = found
            if let found, warning.check(found) {
                let (title, body) = strings.allowanceWarning(found)
                Notifier.post(title: title, body: body)
            }
        }
    }
}
