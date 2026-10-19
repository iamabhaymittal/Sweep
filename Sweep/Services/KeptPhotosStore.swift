import Foundation

/// Remembers the photos the user swiped to keep, so the deck skips them in later sessions.
/// Stored as a JSON array of Photos local identifiers in Application Support.
final class KeptPhotosStore {
    private(set) var identifiers: Set<String>
    private let writer: KeptPhotosWriter
    /// Increases with every change, so the writer can drop snapshots that arrive out of order.
    private var version = 0

    init(fileURL: URL = KeptPhotosStore.defaultFileURL) {
        writer = KeptPhotosWriter(fileURL: fileURL)
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            identifiers = Set(saved)
        } else {
            identifiers = []
        }
    }

    func insert(_ identifier: String) {
        guard identifiers.insert(identifier).inserted else { return }
        save()
    }

    func remove(_ identifier: String) {
        guard identifiers.remove(identifier) != nil else { return }
        save()
    }

    /// Encoding and writing happen off the main actor; with thousands of kept photos a
    /// synchronous write on every swipe would drop frames mid-animation.
    private func save() {
        version += 1
        let snapshot = Array(identifiers)
        let version = version
        let writer = writer
        Task { await writer.write(snapshot, version: version) }
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "KeptPhotos.json")
    }
}

/// Serializes writes to the kept-photos file.
private actor KeptPhotosWriter {
    private let fileURL: URL
    private var writtenVersion = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func write(_ identifiers: [String], version: Int) {
        // Tasks aren't guaranteed to arrive in order; never let an older snapshot win.
        guard version > writtenVersion else { return }
        writtenVersion = version
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(identifiers).write(to: fileURL, options: .atomic)
        } catch {
            // Losing a save only means a kept photo may reappear in the deck; not worth surfacing.
            print("KeptPhotosStore save failed: \(error)")
        }
    }
}
