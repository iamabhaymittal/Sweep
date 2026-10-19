import Foundation
import Observation
import Photos
import SwiftData

/// Runs photo analysis over the whole library in the background and persists the results, so
/// only new or edited photos are analyzed on later launches.
@Observable
final class AnalysisService {
    private(set) var isRunning = false
    /// Photos analyzed in the current run, out of how many need it.
    private(set) var progress: ScanProgress?
    /// Bumped after every saved batch, so screens showing results know to reload.
    private(set) var resultsVersion = 0

    @ObservationIgnored private let store: AnalysisStore?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    /// A nil container disables analysis rather than crashing; the rest of the app still works.
    init(container: ModelContainer?) {
        store = container.map { AnalysisStore(modelContainer: $0) }
    }

    /// Starts a run unless one is already going. Cheap to call often: an up-to-date library
    /// finishes almost immediately.
    func start() {
        guard let store, runTask == nil else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        runTask = Task {
            await run(store)
            runTask = nil
        }
    }

    func results() async -> [AnalysisResult] {
        (try? await store?.allResults()) ?? []
    }

    // MARK: Run

    private nonisolated struct Item: Sendable {
        let id: String
        let modificationDate: Date
    }

    private func run(_ store: AnalysisStore) async {
        isRunning = true
        defer {
            isRunning = false
            progress = nil
        }

        let library = await Self.libraryImages()
        let known = (try? await store.modificationDates()) ?? [:]

        // Forget photos that have since been deleted.
        let current = Set(library.map(\.id))
        try? await store.delete(known.keys.filter { !current.contains($0) })

        let todo = library.filter { known[$0.id] != $0.modificationDate }
        guard !todo.isEmpty else { return }

        progress = ScanProgress(done: 0, total: todo.count)
        var start = 0
        while start < todo.count {
            let end = min(start + DetectionConfig.analysisBatchSize, todo.count)
            let results = await Self.analyze(Array(todo[start..<end]), concurrency: Self.concurrency())
            try? await store.upsert(results)
            start = end
            progress = ScanProgress(done: end, total: todo.count)
            resultsVersion += 1
        }
    }

    /// Every photo (not video), newest first so recent photos get results soonest.
    @concurrent
    nonisolated private static func libraryImages() async -> [Item] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var items: [Item] = []
        items.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            items.append(Item(id: asset.localIdentifier, modificationDate: asset.modificationDate ?? .distantPast))
        }
        return items
    }

    /// Analyzes a batch with at most `concurrency` photos in flight.
    @concurrent
    nonisolated private static func analyze(_ items: [Item], concurrency: Int) async -> [AnalysisResult] {
        await withTaskGroup(of: AnalysisResult?.self) { group in
            var remaining = items.makeIterator()
            for _ in 0..<concurrency {
                guard let item = remaining.next() else { break }
                group.addTask { await ImageAnalyzer.analyze(item.id, modificationDate: item.modificationDate) }
            }
            var results: [AnalysisResult] = []
            for await result in group {
                if let result { results.append(result) }
                if let item = remaining.next() {
                    group.addTask { await ImageAnalyzer.analyze(item.id, modificationDate: item.modificationDate) }
                }
            }
            return results
        }
    }

    /// Halved in Low Power Mode or when the device is hot, re-checked every batch.
    nonisolated private static func concurrency() -> Int {
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        return max(1, constrained ? DetectionConfig.analysisConcurrency / 2 : DetectionConfig.analysisConcurrency)
    }
}
