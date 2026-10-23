import Foundation

/// A point on a trip's charts: how fast the train went over the last half minute or so, and how late it was.
public struct RideSample: Codable, Sendable, Equatable {
    /// Seconds since the trip started.
    public var time: Int
    /// Kilometers since the trip started.
    public var distance: Double
    /// Average km/h since the previous sample; `nil` when the portal had no speed.
    public var speed: Int?
    /// Minutes late at the next stop.
    public var delay: Int?
    /// Delay reasons that came up here for the first time on this trip.
    public var reasons: [String]?

    public init(time: Int, distance: Double, speed: Int? = nil, delay: Int? = nil, reasons: [String]? = nil) {
        self.time = time
        self.distance = distance
        self.speed = speed
        self.delay = delay
        self.reasons = reasons
    }

    // Short keys: every trip keeps up to a few hundred of these.
    enum CodingKeys: String, CodingKey {
        case time = "t", distance = "km", speed = "kmh", delay, reasons
    }

    /// One sample for two in a row, as if sampled half as often.
    func merged(with next: RideSample) -> RideSample {
        let speed = switch (speed, next.speed) {
        case let (a?, b?): Int((Double(a + b) / 2).rounded())
        case let (a, b): a ?? b
        }
        let reasons = (reasons ?? []) + (next.reasons ?? [])
        return RideSample(time: next.time, distance: next.distance, speed: speed, delay: next.delay ?? delay,
                          reasons: reasons.isEmpty ? nil : reasons)
    }
}

/// Turns the statuses of a trip on board into a sample every 30 s. Long trips keep their shape at a coarser step:
/// at `limit` samples, each pair is merged into one and the step doubles, so no trip stores more than that.
public struct RideSampler: Sendable {
    /// The sample being filled: when it began, and the speeds read so far.
    struct Open: Sendable {
        var start: TimeInterval
        var sample = RideSample(time: 0, distance: 0)
        var speedSum = 0
        var speedCount = 0
    }

    public private(set) var samples: [RideSample] = []
    /// Seconds per sample.
    public private(set) var interval: TimeInterval
    let limit: Int
    private var open: Open?
    private var seenReasons: Set<String> = []

    public init(interval: TimeInterval = 30, limit: Int = 240) {
        self.interval = interval
        self.limit = limit
    }

    /// Takes the status `time` seconds into the trip, `distance` km after it started.
    public mutating func record(_ status: TrainStatus, distance: Double, at time: TimeInterval) {
        if let open, time - open.start >= interval { close() }
        var current = open ?? Open(start: time)
        current.sample.time = Int(time.rounded())
        current.sample.distance = (distance * 10).rounded() / 10
        if let speed = status.speed {
            current.speedSum += speed
            current.speedCount += 1
            current.sample.speed = Int((Double(current.speedSum) / Double(current.speedCount)).rounded())
        }
        let next = status.nextStop
        current.sample.delay = next?.delayMinutes ?? current.sample.delay
        let new = (next?.delayReasons ?? []).filter { seenReasons.insert($0).inserted }
        if !new.isEmpty { current.sample.reasons = (current.sample.reasons ?? []) + new }
        open = current
    }

    /// The samples so far with the one still being filled: what the live chart shows and a finished trip keeps.
    public var all: [RideSample] {
        guard let open else { return samples }
        return samples + [open.sample]
    }

    private mutating func close() {
        guard let open else { return }
        samples.append(open.sample)
        self.open = nil
        guard samples.count >= limit else { return }
        samples = stride(from: 0, to: samples.count, by: 2).map { index in
            index + 1 < samples.count ? samples[index].merged(with: samples[index + 1]) : samples[index]
        }
        interval *= 2
    }
}

extension [RideSample] {
    /// Stretches to draw as one line each. A missing value, or a gap in the data (Wi-Fi gone for more than three
    /// sampling steps), breaks the line instead of bridging it.
    public func runs(of value: KeyPath<RideSample, Int?>) -> [[RideSample]] {
        let steps = zip(self, dropFirst()).map { $1.time - $0.time }.sorted()
        let gap = steps.isEmpty ? Int.max : 3 * Swift.max(steps[steps.count / 2], 1)
        var runs: [[RideSample]] = []
        var previous: RideSample?
        for sample in self {
            defer { previous = sample }
            guard sample[keyPath: value] != nil else { continue }
            if let previous, previous[keyPath: value] != nil, sample.time - previous.time <= gap {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }
        return runs
    }
}
