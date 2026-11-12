import Foundation
import Observation
import ZugbarCore

/// Trips on board, recorded from portal data and kept in Application Support like the learned speeds.
@MainActor
@Observable
final class TripStore {
    /// Finished trips, newest first.
    private(set) var log = TripStore.load()
    /// The trip on board so far, for the live chart.
    private(set) var live: Trip?
    @ObservationIgnored private var recorder = TripRecorder() {
        didSet {
            let current = recorder.current
            if current != live { live = current }
        }
    }

    /// When the ride on board was last written to the log.
    @ObservationIgnored private var savedAt = Date.distantPast

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zugbar/trips.json")
    }

    private static func load() -> TripLog {
        (try? JSONDecoder().decode(TripLog.self, from: Data(contentsOf: file))) ?? TripLog()
    }

    func record(_ status: TrainStatus) {
        let now = Date()
        // After a restart in the middle of a ride, the trip logged so far goes on instead of a new one starting.
        if recorder.current == nil, let last = log.trips.first { _ = recorder.resume(last, with: status, at: now) }
        if let trip = recorder.update(status, at: now) { add(trip) }
        // Logged as it grows, so a restart or a crash finds the ride so far. Not rides too short to count.
        if let riding = recorder.current, now.timeIntervalSince(savedAt) >= 60,
           riding.distance >= TripRecorder.minimumDistance, riding.duration >= TripRecorder.minimumDuration {
            savedAt = now
            add(riding)
        }
    }

    /// Ends a trip that hasn't been heard from for a while; cheap enough to call every second.
    func finishIfIdle() {
        guard let trip = recorder.finishIfIdle(at: Date()) else { return }
        add(trip)
    }

    /// Ends the trip on board, e.g. when tracking stops, the train changes or the app quits.
    func finish() {
        guard let trip = recorder.finish() else { return }
        add(trip)
    }

    func delete(_ id: Trip.ID) {
        log.remove(id)
        save()
    }

    private func add(_ trip: Trip) {
        log.add(trip)
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(log).write(to: Self.file, options: .atomic)
    }
}
