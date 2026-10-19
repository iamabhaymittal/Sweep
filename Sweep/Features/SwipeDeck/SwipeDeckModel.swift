import Foundation
import Observation
import Photos
import UIKit

/// What the user decided for a single card.
enum SwipeDecision: Equatable {
    case keep
    case delete
}

/// Which part of the library a deck reviews.
enum DeckMediaType {
    case photos
    case videos

    var assetMediaType: PHAssetMediaType {
        switch self {
        case .photos: .image
        case .videos: .video
        }
    }
}

/// The order cards are dealt in.
enum DeckOrder: CaseIterable, Identifiable {
    case largestFirst
    case newestFirst

    var id: Self { self }

    var title: String {
        switch self {
        case .largestFirst: "Largest First"
        case .newestFirst: "Newest First"
        }
    }
}

/// The outcome of one Delete tap.
struct CleanupResult: Equatable, Identifiable {
    let id = UUID()
    let itemCount: Int
    let bytes: Int64
}

/// Drives the keep/delete deck: orders the library, skips items kept in earlier sessions,
/// records decisions, preloads upcoming images, and deletes the marked items in a single batch.
@Observable
final class SwipeDeckModel {
    private struct Swipe {
        let assetID: String
        let decision: SwipeDecision
    }

    /// Pixel size requested for card images; large enough for a full-width card on any iPhone.
    private static let cardImageSize = CGSize(width: 1200, height: 1600)

    private(set) var mediaType: DeckMediaType = .photos
    private(set) var order: DeckOrder = .largestFirst
    private(set) var isLoading = true
    private(set) var isDeleting = false
    private(set) var currentIndex = 0
    private(set) var images: [String: UIImage] = [:]
    /// Set after each successful delete, for the confirmation banner.
    var lastCleanup: CleanupResult?
    private(set) var sessionCleanup = CleanupTotals()
    var errorMessage: String?

    /// Identifiers in deal order. Items kept in earlier sessions are never included.
    private var deck: [String] = []
    private var history: [Swipe] = []
    /// Assets for the cards around the current position, fetched on demand.
    private var assets: [String: PHAsset] = [:]
    @ObservationIgnored private var fileSizes: [String: Int64] = [:]
    @ObservationIgnored private var library: PhotoLibraryService?
    @ObservationIgnored private var source: (() async -> [String])?
    @ObservationIgnored private let keptStore = KeptPhotosStore()
    @ObservationIgnored private let imageManager = PHCachingImageManager()
    /// Identifiers with an image request already in flight, so preloading never requests twice.
    @ObservationIgnored private var pendingRequests: Set<String> = []

    var totalCount: Int { deck.count }
    var isFinished: Bool { !isLoading && currentIndex >= deck.count }
    var canUndo: Bool { !history.isEmpty && !isDeleting }
    var markedForDeletionCount: Int { history.count { $0.decision == .delete } }

    /// The current card followed by the next couple, top card first.
    var visibleAssets: [PHAsset] {
        let end = min(currentIndex + 3, deck.count)
        guard currentIndex < end else { return [] }
        return deck[currentIndex..<end].compactMap { assets[$0] }
    }

    func fileSize(of asset: PHAsset) -> Int64? {
        fileSizes[asset.localIdentifier]
    }

    // MARK: Loading

    /// - Parameter source: A curated, pre-ordered list (e.g. low-value shots) to deal instead of the
    ///   whole library. Curated decks keep their own order, so they can't be re-sorted.
    func load(
        _ mediaType: DeckMediaType,
        library: PhotoLibraryService,
        source: (() async -> [String])? = nil
    ) async {
        guard self.library == nil else { return }
        self.mediaType = mediaType
        self.library = library
        self.source = source
        await rebuildDeck()
    }

    var canReorder: Bool { source == nil }

    func setOrder(_ newOrder: DeckOrder) async {
        guard newOrder != order, !isLoading, !isDeleting else { return }
        order = newOrder
        await rebuildDeck()
    }

    /// Re-sorts the unreviewed items. Items already swiped this session stay ahead of
    /// `currentIndex` in their original order, so undo and pending deletions survive a re-sort.
    private func rebuildDeck() async {
        guard let library else { return }
        isLoading = true
        defer { isLoading = false }

        // Sizes are needed for both orders: the card badges and the freed-space total use them.
        let sizes = await library.loadSizes().sizes
        var identifiers = if let source {
            await source()
        } else {
            await Self.fetchIdentifiers(of: mediaType.assetMediaType)
        }
        guard !Task.isCancelled else { return }

        if order == .largestFirst, source == nil {
            // Items without a readable size go last, keeping their newest-first order.
            identifiers = identifiers.enumerated().sorted { lhs, rhs in
                switch (sizes[lhs.element], sizes[rhs.element]) {
                case let (l?, r?) where l != r: l > r
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }.map(\.element)
        }

        // Keep sizes of items swiped earlier this session, even if a rescan has dropped them.
        fileSizes.merge(sizes) { _, new in new }
        let reviewed = history.map(\.assetID)
        let excluded = keptStore.identifiers.union(reviewed)
        deck = reviewed + identifiers.filter { !excluded.contains($0) }
        currentIndex = reviewed.count
        assets.removeAll()
        images.removeAll()
        preloadImages()
    }

    /// Local identifiers of every asset of `mediaType`, newest first.
    @concurrent
    nonisolated private static func fetchIdentifiers(of mediaType: PHAssetMediaType) async -> [String] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: mediaType, options: options)
        var identifiers: [String] = []
        identifiers.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            identifiers.append(asset.localIdentifier)
        }
        return identifiers
    }

    // MARK: Decisions

    func swipe(_ decision: SwipeDecision) {
        guard currentIndex < deck.count, !isDeleting else { return }
        let id = deck[currentIndex]
        history.append(Swipe(assetID: id, decision: decision))
        if decision == .keep {
            // Saved immediately so the item stays skipped even if the app is closed mid-session.
            keptStore.insert(id)
        }
        currentIndex += 1
        preloadImages()
    }

    func undo() {
        guard canUndo, let last = history.popLast() else { return }
        if last.decision == .keep {
            keptStore.remove(last.assetID)
        }
        currentIndex -= 1
        preloadImages()
    }

    /// Deletes every item marked so far. Photos shows its own confirmation alert.
    func deleteMarked() async {
        let identifiers = history.filter { $0.decision == .delete }.map(\.assetID)
        guard !identifiers.isEmpty, !isDeleting else { return }

        isDeleting = true
        defer { isDeleting = false }

        do {
            guard try await LibraryDeletion.delete(identifiers) else { return }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let bytes = identifiers.compactMap { fileSizes[$0] }.reduce(0, +)
        let result = CleanupResult(itemCount: identifiers.count, bytes: bytes)
        lastCleanup = result
        sessionCleanup.itemCount += result.itemCount
        sessionCleanup.bytes += result.bytes
        library?.recordCleanup(itemCount: result.itemCount, bytes: result.bytes)

        // Every marked item sits before `currentIndex`, so removing them shifts it back by
        // the same amount. Keeps are already saved, so the cleared history loses nothing.
        let deleted = Set(identifiers)
        deck.removeAll { deleted.contains($0) }
        currentIndex = max(0, currentIndex - identifiers.count)
        history.removeAll()
        preloadImages()
    }

    // MARK: Image preloading

    /// Identifiers of the current card plus the next `deckPreloadCount`, and the previous card for undo.
    private var windowIDs: ArraySlice<String> {
        let lower = max(currentIndex - 1, 0)
        let upper = min(currentIndex + DetectionConfig.deckPreloadCount + 1, deck.count)
        return lower < upper ? deck[lower..<upper] : []
    }

    /// Loads assets and images for the window and drops everything else,
    /// so memory stays flat however far the user swipes.
    private func preloadImages() {
        let window = windowIDs
        let missing = window.filter { assets[$0] == nil }
        if !missing.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(missing), options: nil)
            fetched.enumerateObjects { asset, _, _ in
                self.assets[asset.localIdentifier] = asset
            }
            // Drop items that were deleted outside the app, so the top card always
            // matches `deck[currentIndex]`. Then try again with the shortened deck.
            let gone = Set(missing.filter { assets[$0] == nil })
            if !gone.isEmpty {
                let before = deck[..<currentIndex].count { gone.contains($0) }
                deck.removeAll { gone.contains($0) }
                history.removeAll { gone.contains($0.assetID) }
                currentIndex -= before
                preloadImages()
                return
            }
        }

        let windowSet = Set(window)
        assets = assets.filter { windowSet.contains($0.key) }
        images = images.filter { windowSet.contains($0.key) }

        for id in window {
            guard let asset = assets[id], images[id] == nil, !pendingRequests.contains(id) else { continue }
            pendingRequests.insert(id)
            Self.requestImage(for: asset, manager: imageManager, targetSize: Self.cardImageSize) { [weak self] image in
                Task { @MainActor in
                    guard let self else { return }
                    self.pendingRequests.remove(id)
                    // Ignore results for cards that left the window while loading.
                    if let image, self.windowIDs.contains(id) {
                        self.images[id] = image
                    }
                }
            }
        }
    }

    /// Nonisolated so PhotoKit can call the result handler from whichever queue it likes.
    /// For videos this returns a still frame, which is what the card shows.
    nonisolated private static func requestImage(
        for asset: PHAsset,
        manager: PHImageManager,
        targetSize: CGSize,
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        let options = PHImageRequestOptions()
        // High quality delivers exactly one callback, rather than a degraded image first.
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        // Aspect fit returns the whole frame; the card letterboxes it rather than cropping.
        manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, _ in
            completion(image)
        }
    }
}
