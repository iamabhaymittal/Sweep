import Foundation
import Observation
import Photos

/// The app's view of Photos authorization, collapsed to the states the UI cares about.
enum LibraryAccess: Equatable {
    case notDetermined
    case full
    case limited
    /// Denied or restricted; either way the app cannot read the library.
    case denied

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .full
        case .limited: self = .limited
        default: self = .denied
        }
    }

    var canRead: Bool { self == .full || self == .limited }
}

/// Item counts for the library breakdown. Hidden-album items are excluded.
struct LibraryCounts: Equatable, Sendable {
    var photos = 0
    var videos = 0
    /// Screenshots plus screen recordings, matching what the Screenshots module covers.
    var screenshots = 0
    var livePhotos = 0

    var total: Int { photos + videos }
}

/// On-disk size of every photo and video, keyed by local identifier.
struct LibrarySizeIndex: Sendable {
    var sizes: [String: Int64] = [:]
    var photoBytes: Int64 = 0
    var videoBytes: Int64 = 0
}

/// How far a size scan has got.
struct ScanProgress: Equatable, Sendable {
    var done: Int
    var total: Int
}

/// Capacity of the device's main volume.
struct DeviceStorage: Equatable, Sendable {
    var total: Int64
    /// Space available for user-initiated work, which counts purgeable space the system can free.
    var available: Int64

    var used: Int64 { max(0, total - available) }
}

/// Running totals of everything deleted through Sweep, across launches.
struct CleanupTotals: Equatable {
    var itemCount = 0
    var bytes: Int64 = 0
}

/// Owns Photos authorization and library-level queries.
@Observable
final class PhotoLibraryService {
    private(set) var access: LibraryAccess
    private(set) var counts: LibraryCounts?
    /// Nil until the first size scan finishes; kept (slightly stale) while a rescan runs.
    private(set) var sizeIndex: LibrarySizeIndex?
    private(set) var sizeScanProgress: ScanProgress?
    private(set) var deviceStorage: DeviceStorage?
    private(set) var cleanupTotals: CleanupTotals

    @ObservationIgnored private var changeObserver: LibraryChangeObserver?
    @ObservationIgnored private var sizeScan: Task<LibrarySizeIndex?, Never>?
    /// Bumped on every library change; an index or scan from an older generation is stale.
    @ObservationIgnored private var libraryGeneration = 0
    @ObservationIgnored private var sizeScanGeneration = 0
    @ObservationIgnored private var sizeIndexGeneration = 0

    private static let cleanupItemsKey = "cleanup.itemCount"
    private static let cleanupBytesKey = "cleanup.bytes"

    init() {
        access = LibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        let defaults = UserDefaults.standard
        cleanupTotals = CleanupTotals(
            itemCount: defaults.integer(forKey: Self.cleanupItemsKey),
            bytes: Int64(defaults.integer(forKey: Self.cleanupBytesKey))
        )
        if access.canRead {
            startObservingChanges()
        }
    }

    // MARK: Authorization

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        updateAccess(LibraryAccess(status))
    }

    /// Re-reads the current status, for when the user returns from Settings.
    func refreshAccess() {
        updateAccess(LibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite)))
    }

    private func updateAccess(_ newAccess: LibraryAccess) {
        guard newAccess != access else { return }
        access = newAccess
        // Going between limited and full access changes which assets are visible.
        libraryGeneration += 1
        if newAccess.canRead {
            startObservingChanges()
        } else {
            changeObserver = nil
            counts = nil
            sizeIndex = nil
        }
    }

    // MARK: Counts

    func loadCounts() async {
        guard access.canRead else { return }
        counts = await Self.fetchCounts()
    }

    /// Fetch counts are cheap, but run them off the main actor so large libraries never stall the UI.
    @concurrent
    nonisolated private static func fetchCounts() async -> LibraryCounts {
        func count(_ mediaType: PHAssetMediaType, subtype: PHAssetMediaSubtype? = nil) -> Int {
            let options = PHFetchOptions()
            // includeHiddenAssets defaults to false, so hidden items are already excluded.
            if let subtype {
                options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", subtype.rawValue)
            }
            return PHAsset.fetchAssets(with: mediaType, options: options).count
        }

        return LibraryCounts(
            photos: count(.image),
            videos: count(.video),
            screenshots: count(.image, subtype: .photoScreenshot) + count(.video, subtype: .videoScreenRecording),
            livePhotos: count(.image, subtype: .photoLive)
        )
    }

    // MARK: Sizes

    /// Returns sizes for the whole library, reusing the cached index or an in-flight scan when
    /// they're current. Measuring touches every asset, so it takes a few seconds on big libraries.
    @discardableResult
    func loadSizes() async -> LibrarySizeIndex {
        guard access.canRead else { return LibrarySizeIndex() }
        if let sizeIndex, sizeIndexGeneration == libraryGeneration {
            return sizeIndex
        }
        if let sizeScan, sizeScanGeneration == libraryGeneration {
            return await result(of: sizeScan)
        }

        // Any running scan is now stale. Stop it rather than run two full-library scans side by side.
        sizeScan?.cancel()
        let generation = libraryGeneration
        let scan = Task { [weak self] () -> LibrarySizeIndex? in
            let index = await Self.scanSizes { progress in
                Task { @MainActor in
                    guard let self, self.sizeScanGeneration == generation, self.sizeScan != nil else { return }
                    self.sizeScanProgress = progress
                }
            }
            self?.finishScan(index, generation: generation)
            return index
        }
        sizeScan = scan
        sizeScanGeneration = generation
        if sizeIndex == nil {
            sizeScanProgress = ScanProgress(done: 0, total: 0)
        }
        return await result(of: scan)
    }

    /// A cancelled scan returns nil because a newer one replaced it; wait for that one instead.
    private func result(of scan: Task<LibrarySizeIndex?, Never>) async -> LibrarySizeIndex {
        if let index = await scan.value {
            return index
        }
        return await loadSizes()
    }

    private func finishScan(_ index: LibrarySizeIndex?, generation: Int) {
        // A newer scan may have finished first; never overwrite it with older results.
        if let index, generation >= sizeIndexGeneration {
            sizeIndex = index
            sizeIndexGeneration = generation
        }
        if sizeScanGeneration == generation {
            sizeScan = nil
            sizeScanProgress = nil
        }
    }

    /// Returns nil if cancelled part-way, so a partial index is never cached or used for sorting.
    @concurrent
    nonisolated private static func scanSizes(progress: @escaping @Sendable (ScanProgress) -> Void) async -> LibrarySizeIndex? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        let total = result.count
        var index = LibrarySizeIndex()
        index.sizes.reserveCapacity(total)

        for position in 0..<total {
            if position.isMultiple(of: 250) {
                if Task.isCancelled { return nil }
                progress(ScanProgress(done: position, total: total))
            }
            let asset = result.object(at: position)
            guard let size = fileSize(of: asset) else { continue }
            index.sizes[asset.localIdentifier] = size
            if asset.mediaType == .video {
                index.videoBytes += size
            } else {
                index.photoBytes += size
            }
        }
        return index
    }

    /// Total bytes across an asset's resources (original, edits, Live Photo video).
    /// PhotoKit has no public size API; `fileSize` on PHAssetResource is the widely used KVC key.
    /// Originals kept only in iCloud ("Optimize iPhone Storage") still report their full size.
    nonisolated static func fileSize(of asset: PHAsset) -> Int64? {
        let sizes = PHAssetResource.assetResources(for: asset).compactMap { resource -> Int64? in
            // value(forKey:) raises an uncatchable exception for an unknown key. Check first, so the
            // app degrades to "size unknown" instead of crashing if a future iOS drops the property.
            guard resource.responds(to: fileSizeSelector) else { return nil }
            return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
        }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    nonisolated private static let fileSizeSelector = NSSelectorFromString("fileSize")

    // MARK: Device storage

    func refreshDeviceStorage() {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity,
              let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        deviceStorage = DeviceStorage(total: Int64(total), available: available)
    }

    // MARK: Cleanup totals

    func recordCleanup(itemCount: Int, bytes: Int64) {
        cleanupTotals.itemCount += itemCount
        cleanupTotals.bytes += bytes
        let defaults = UserDefaults.standard
        defaults.set(cleanupTotals.itemCount, forKey: Self.cleanupItemsKey)
        defaults.set(Int(cleanupTotals.bytes), forKey: Self.cleanupBytesKey)
    }

    // MARK: Change observation

    /// Only registered once access is granted; registering earlier would trigger the permission prompt.
    private func startObservingChanges() {
        guard changeObserver == nil else { return }
        changeObserver = LibraryChangeObserver { [weak self] in
            Task { @MainActor in
                await self?.libraryDidChange()
            }
        }
    }

    private func libraryDidChange() async {
        libraryGeneration += 1
        let generation = libraryGeneration

        // iCloud sync can deliver hundreds of changes in a burst. Only the last change in a
        // quiet second does any work, so a burst costs one refresh instead of hundreds.
        try? await Task.sleep(for: .seconds(1))
        guard generation == libraryGeneration else { return }

        refreshDeviceStorage()
        await loadCounts()
        if sizeIndex != nil {
            await loadSizes()
        }
    }
}

/// Bridges PhotoKit's change callbacks, which arrive on a background queue, to a Sendable closure.
nonisolated private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
