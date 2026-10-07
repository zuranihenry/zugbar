import AppKit
import ZugbarCore

/// Saves raw on-board portal responses while switched on (Settings → Debug), to turn real trips into test
/// fixtures and to look into problems afterwards. At most one file per endpoint and minute; stays on this Mac.
enum PortalRecorder {
    static let enabledKey = "recordPortals"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zugbar/Recordings", isDirectory: true)
    }

    private static let store = RecordingStore()

    static func wrap(_ loader: @escaping DataLoader) -> DataLoader {
        { url in
            let data = try await loader(url)
            if isEnabled { await store.save(data, from: url) }
            return data
        }
    }

    static func showInFinder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private actor RecordingStore {
    private var lastSaved: [String: Date] = [:]

    func save(_ data: Data, from url: URL) {
        let endpoint = (url.host ?? "") + url.path
        let now = Date()
        if let last = lastSaved[endpoint], now.timeIntervalSince(last) < 60 { return }
        lastSaved[endpoint] = now

        let day = now.formatted(.iso8601.year().month().day())
        let time = now.formatted(.iso8601.time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let slug = endpoint.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        let folder = PortalRecorder.folder.appendingPathComponent(day, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("\(time)-\(slug).json"))
    }
}
