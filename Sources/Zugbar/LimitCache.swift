import CryptoKit
import Foundation
import ZugbarCore

/// Speed limits per route section, kept on disk so recurring trips don't hit OpenStreetMap again.
actor LimitCache {
    private struct Entry: Codable {
        var limits: [Int]
        var used: Date
    }

    private let file: URL
    private var entries: [String: Entry]
    private static let maxEntries = 300

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zugbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("speed-limits.json")
        let data = try? Data(contentsOf: file)
        if let data, let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = entries
        } else if let data, let old = try? JSONDecoder().decode([String: [Int]].self, from: data) {
            // Files from older versions only stored the limits.
            entries = old.mapValues { Entry(limits: $0, used: .distantPast) }
        } else {
            entries = [:]
        }
    }

    /// The section's shape (start, end, length rounded) identifies it independent of trip IDs.
    static func key(for points: [Coordinate]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let route = Route(points: points)
        let text = String(format: "%.3f,%.3f-%.3f,%.3f-%d", first.latitude, first.longitude, last.latitude, last.longitude, Int(route.length / 500))
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Marks the entry as used in memory; it's written to disk with the next store.
    func limits(for key: String) -> [Int]? {
        entries[key]?.used = Date()
        return entries[key]?.limits
    }

    /// Stores limits, dropping the least recently used section when full.
    func store(_ limits: [Int], for key: String) {
        if entries[key] == nil, entries.count >= Self.maxEntries,
           let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(limits: limits, used: Date())
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
