import Foundation
import ZugbarCore

/// Keeps what Zugbar learns on board (speeds, Wi-Fi) on disk, on this Mac only. Writes are batched, since
/// observations arrive every few seconds on board.
actor LearnedStore<Value: Codable & Sendable> {
    private let file: URL
    private let empty: Value
    private(set) var value: Value
    private var unsaved = 0

    init(file name: String, empty: Value) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zugbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent(name)
        self.empty = empty
        value = (try? JSONDecoder().decode(Value.self, from: Data(contentsOf: file))) ?? empty
    }

    func update(_ change: @Sendable (inout Value) -> Void) {
        change(&value)
        unsaved += 1
        if unsaved >= 10 { save() }
    }

    func save() {
        guard unsaved > 0 else { return }
        unsaved = 0
        try? JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    func clear() {
        value = empty
        unsaved = 0
        try? FileManager.default.removeItem(at: file)
    }
}
