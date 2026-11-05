import AppKit
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
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Before the first answer, failures are more likely a login page not yet passed or a firewall than the train.
    @ObservationIgnored private var answeredOnce = false

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

    init() {
        // Requests lost while asleep and reconnecting say nothing about the train's Wi-Fi.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget() }
        }
    }

    private func forget() {
        probe.reset()
        answeredOnce = false
        reading = nil
    }

    /// Starts measuring, or stops and forgets the last reading.
    func run(_ on: Bool) {
        guard on != isRunning else { return }
        if on {
            task = Task { [weak self] in await self?.loop() }
        } else {
            task?.cancel()
            task = nil
            forget()
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
            let outcome = await Self.measure()
            guard !Task.isCancelled else { return }
            if case .answered(let latency) = outcome {
                answeredOnce = true
                probe.record(latency: latency, at: Date())
            } else if outcome == .lost, answeredOnce {
                probe.record(latency: nil, at: Date())
            }
            _ = current(at: Date())
            try? await Task.sleep(for: .seconds(probe.interval(at: Date())))
        }
    }

    private enum Outcome: Equatable {
        /// Time from sending the request to the first byte of the answer.
        case answered(TimeInterval)
        case lost
        /// Not the train's doing: the Mac isn't on a network at all, e.g. while the Wi-Fi reconnects, or not logged in.
        case offline
    }

    /// Times only the request, not setting up the connection, so a fresh connection doesn't count as a slow one.
    nonisolated private static func measure() async -> Outcome {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let metrics = MetricsCatcher()
        let started = Date()
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request, delegate: metrics)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost].contains(error.code) {
            return .offline
        } catch {
            return .lost
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return .lost }
        // Redirected elsewhere: a login page, not the train's uplink.
        guard response.url?.host == url.host else { return .offline }
        if let transaction = metrics.value?.transactionMetrics.last,
           let sent = transaction.requestStartDate, let answered = transaction.responseStartDate {
            return .answered(answered.timeIntervalSince(sent))
        }
        return .answered(Date().timeIntervalSince(started))
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
