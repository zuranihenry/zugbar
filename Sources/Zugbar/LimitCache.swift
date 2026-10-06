import CryptoKit
import Foundation
import ZugbarCore

/// Speed limits per route section, kept on disk so recurring trips don't hit OpenStreetMap again.
actor LimitCache {
    private let file: URL
    private var entries: [String: [Int]]
    private static let maxEntries = 300

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zugbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("speed-limits.json")
        entries = (try? JSONDecoder().decode([String: [Int]].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// The section's shape (start, end, length rounded) identifies it independent of trip IDs.
    static func key(for points: [Coordinate]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let route = Route(points: points)
        let text = String(format: "%.3f,%.3f-%.3f,%.3f-%d", first.latitude, first.longitude, last.latitude, last.longitude, Int(route.length / 500))
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func limits(for key: String) -> [Int]? { entries[key] }

    func store(_ limits: [Int], for key: String) {
        if entries.count >= Self.maxEntries, let oldest = entries.keys.first { entries.removeValue(forKey: oldest) }
        entries[key] = limits
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
