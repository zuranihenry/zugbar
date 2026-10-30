import Foundation

/// How the train Wi-Fi's way to the internet actually does, from small requests sent now and then. The ICE portal
/// reports its own uplink, which it calls good while pages crawl or nothing gets through, above all between tunnels.
public struct LinkProbe: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public var quality: Internet.Quality
        /// Median time to an answer over the window; `nil` when nothing answered.
        public var latency: TimeInterval?
        /// Requests in the window and how many of them got no answer.
        public var sent: Int
        public var lost: Int

        /// Weak because answers take long rather than because some never came.
        public var isSlow: Bool { quality == .weak && lost == 0 }
    }

    struct Sample: Sendable, Equatable {
        var date: Date
        /// `nil`: no answer.
        var latency: TimeInterval?
    }

    /// How far back a reading looks: after a dropout the Wi-Fi stays weak this long, since between tunnels the next
    /// one is rarely far, and "good" means pages load, not that they did a moment ago.
    public static let window: TimeInterval = 120
    /// Answers slower than this make browsing a chore.
    public static let slow: TimeInterval = 0.8
    /// Without a request for this long, e.g. after a sleep, there's no reading.
    static let stale: TimeInterval = 90

    private var samples: [Sample] = []

    public init() {}

    /// One request's outcome: how long the answer took, or `nil` when none came.
    public mutating func record(latency: TimeInterval?, at date: Date) {
        samples.append(Sample(date: date, latency: latency))
        samples.removeAll { date.timeIntervalSince($0.date) > Self.window }
    }

    public mutating func reset() { samples = [] }

    public func reading(at date: Date) -> Reading? {
        let recent = samples.filter { date.timeIntervalSince($0.date) <= Self.window }
        guard let last = recent.last, date.timeIntervalSince(last.date) <= Self.stale else { return nil }
        let answers = recent.compactMap(\.latency).sorted()
        let lost = recent.count - answers.count
        let latency = answers.isEmpty ? nil : answers[answers.count / 2]

        let quality: Internet.Quality
        if last.latency == nil {
            // One lost request is a hiccup; two in a row is no internet.
            quality = recent.suffix(2).allSatisfy { $0.latency == nil } && recent.count >= 2 ? .none : .weak
        } else if lost > 0 || (latency ?? 0) > Self.slow {
            quality = .weak
        } else {
            quality = .good
        }
        return Reading(quality: quality, latency: latency, sent: recent.count, lost: lost)
    }

    /// When to send the next request: soon after one went unanswered, which costs no data and tells a tunnel from a
    /// hiccup quickly; more often while the Wi-Fi is changing; less while it's steady and good.
    /// Never much longer than 20 s, or the server drops the kept-alive connection and every request pays for a new
    /// TLS handshake, ten times what the request itself costs.
    public func interval(at date: Date) -> TimeInterval {
        if let last = samples.last, last.latency == nil { return 5 }
        return reading(at: date).map { $0.quality == .good && $0.sent >= 3 } == true ? 20 : 15
    }
}

extension Internet {
    /// The portal's level, or the measured one where that's worse: neither alone tells the whole story, and the
    /// portal's forecast of the change ahead stays.
    public static func combining(portal: Internet?, measured: LinkProbe.Reading?) -> Internet? {
        guard let measured else { return portal }
        guard var internet = portal else { return Internet(current: measured.quality) }
        if measured.quality.severity > internet.current.severity { internet.current = measured.quality }
        return internet
    }
}
