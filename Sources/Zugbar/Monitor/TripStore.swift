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

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zugbar/trips.json")
    }

    private static func load() -> TripLog {
        (try? JSONDecoder().decode(TripLog.self, from: Data(contentsOf: file))) ?? TripLog()
    }

    func record(_ status: TrainStatus) {
        guard let trip = recorder.update(status, at: Date()) else { return }
        add(trip)
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
