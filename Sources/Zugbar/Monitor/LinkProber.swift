import Foundation
import Observation
import ZugbarCore

/// Measures the train Wi-Fi's internet while on board, with a HEAD request every 15 to 20 seconds: about 650 bytes
/// each over a kept-alive connection, some 150 KB an hour, which matters on trains whose Wi-Fi has a data limit.
@MainActor
@Observable
final class LinkProber {
    private(set) var reading: LinkProbe.Reading?

    @ObservationIgnored private var probe = LinkProbe()
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Apple's own captive-portal check, which macOS asks anyway; it answers with a tiny page.
    nonisolated private static let url = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    nonisolated private static let timeout: TimeInterval = 6

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    var isRunning: Bool { task != nil }

    /// Starts measuring, or stops and forgets the last reading.
    func run(_ on: Bool) {
        guard on != isRunning else { return }
        if on {
            task = Task { [weak self] in await self?.loop() }
        } else {
            task?.cancel()
            task = nil
            probe.reset()
            reading = nil
        }
    }

    /// The reading now, `nil` once the last request is too long ago, e.g. after a sleep.
    func current(at date: Date) -> LinkProbe.Reading? {
        let reading = probe.reading(at: date)
        if reading != self.reading { self.reading = reading }
        return reading
    }

    private func loop() async {
        while !Task.isCancelled {
            let latency = await Self.measure()
            guard !Task.isCancelled else { return }
            probe.record(latency: latency, at: Date())
            _ = current(at: Date())
            try? await Task.sleep(for: .seconds(probe.interval(at: Date())))
        }
    }

    /// Time from sending the request to the first byte of the answer, without setting up the connection, so a
    /// fresh connection doesn't count as a slow one; `nil` when no answer came in time.
    nonisolated private static func measure() async -> TimeInterval? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let metrics = MetricsCatcher()
        let started = Date()
        guard let (_, response) = try? await session.data(for: request, delegate: metrics),
              let response = response as? HTTPURLResponse, response.statusCode == 200,
              // Not yet logged in, a captive portal redirects elsewhere: that's no internet either.
              response.url?.host == url.host
        else { return nil }
        if let transaction = metrics.value?.transactionMetrics.last,
           let sent = transaction.requestStartDate, let answered = transaction.responseStartDate {
            return answered.timeIntervalSince(sent)
        }
        return Date().timeIntervalSince(started)
    }
}

private final class MetricsCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    var value: URLSessionTaskMetrics? { lock.withLock { metrics } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { self.metrics = metrics }
    }
}
