import Foundation
import ZugbarCore

/// Keeps learned speeds on disk. Writes are batched, since observations arrive every few seconds on board.
actor LearnedSpeedStore {
    private let file: URL
    private(set) var speeds: LearnedSpeeds
    private var unsaved = 0

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zugbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("learned-speeds.json")
        speeds = (try? JSONDecoder().decode(LearnedSpeeds.self, from: Data(contentsOf: file))) ?? LearnedSpeeds()
    }

    func record(_ coordinate: Coordinate, speed: Int, kind: TrainKind) {
        speeds.record(coordinate, speed: speed, kind: kind)
        unsaved += 1
        if unsaved >= 10 { save() }
    }

    func save() {
        guard unsaved > 0 else { return }
        unsaved = 0
        try? JSONEncoder().encode(speeds).write(to: file, options: .atomic)
    }

    func clear() {
        speeds = LearnedSpeeds()
        unsaved = 0
        try? FileManager.default.removeItem(at: file)
    }
}
