import Foundation
import Observation
import ZugbarCore

/// Looks for a newer release on GitHub about once a day and notifies once per new version.
/// Only in the bundled app, which knows its own version.
@MainActor
@Observable
final class UpdateChecker {
    static let enabledKey = "checkForUpdates"

    private(set) var available: Release?

    private var currentVersion: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    private var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var checking = false

    func start() {
        guard loop == nil, currentVersion != nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.check(ifDue: true)
                try? await Task.sleep(for: .seconds(3 * 3600))
            }
        }
    }

    /// `ifDue` skips the request when the last successful check was less than a day ago.
    func check(ifDue: Bool = false) {
        guard isEnabled, !checking, let currentVersion else { return }
        let defaults = UserDefaults.standard
        if ifDue, let last = defaults.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        checking = true
        Task {
            defer { checking = false }
            guard let release = try? await Release.latest() else { return }
            defaults.set(Date(), forKey: "lastUpdateCheck")
            guard Release.isVersion(release.version, newerThan: currentVersion) else {
                available = nil
                return
            }
            available = release
            if defaults.string(forKey: "notifiedUpdate") != release.version {
                defaults.set(release.version, forKey: "notifiedUpdate")
                let (title, body) = Strings(AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system)
                    .updateNotification(release.version)
                Notifier.post(title: title, body: body, url: release.url)
            }
        }
    }
}
