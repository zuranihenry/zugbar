import Foundation

/// Trains and regional lines the user has followed, for "For you" suggestions.
public struct TrainHistory: Codable, Sendable, Equatable {
    public enum Item: Codable, Sendable, Hashable {
        /// A long-distance train, e.g. "ICE 591".
        case train(String)
        /// A regional line at a station, e.g. S3 from Hannover Hbf.
        case line(stationID: String, stationName: String, line: String)

        public var title: String {
            switch self {
            case .train(let name): name
            case .line(_, let station, let line): "\(line) · \(station)"
            }
        }
    }

    struct Entry: Codable, Sendable, Equatable {
        var item: Item
        var uses: [Date]
    }

    private var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func record(_ item: Item, at date: Date = Date()) {
        if let index = entries.firstIndex(where: { $0.item == item }) {
            entries[index].uses = Array((entries[index].uses + [date]).suffix(30))
        } else {
            entries.append(Entry(item: item, uses: [date]))
        }
        // Uses older than 90 days no longer count toward suggestions, so drop them.
        entries.removeAll { entry in entry.uses.allSatisfy { date.timeIntervalSince($0) > 90 * 86_400 } }
    }

    public mutating func remove(_ item: Item) {
        entries.removeAll { $0.item == item }
    }

    /// Ranks by how often, how recently and how close to this time of day an item was used,
    /// so the 07:50 commute train comes first in the morning.
    public func suggestions(at now: Date = Date(), limit: Int = 4, calendar: Calendar = .current) -> [Item] {
        func minuteOfDay(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        let nowMinute = minuteOfDay(now)

        func score(_ entry: Entry) -> Double {
            entry.uses.reduce(0) { total, use in
                let ageDays = now.timeIntervalSince(use) / 86_400
                guard ageDays < 90 else { return total }
                let gap = abs(minuteOfDay(use) - nowMinute)
                let closeness = max(0, 1 - Double(min(gap, 1440 - gap)) / 90)
                return total + exp(-ageDays / 30) * (1 + 2 * closeness)
            }
        }

        return entries
            .map { ($0.item, score($0)) }
            .filter { $0.1 > 0.05 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
