import Foundation

/// Every tunable threshold used by detection, grouping and the swipe deck.
/// Adjust these after testing against the real library.
/// Nonisolated: these are constants, read by analysis code running off the main actor.
nonisolated enum DetectionConfig {
    // MARK: Duplicates

    /// Maximum Hamming distance between two 64-bit dHashes for photos to count as duplicates.
    static let duplicateHammingDistance = 3
    /// Side length of the thumbnail the dHash is computed from.
    static let hashThumbnailSize = 256

    // MARK: Similar

    /// Photos taken further apart than this are never grouped as similar.
    static let similarTimeWindow: TimeInterval = 10 * 60

    // MARK: Low-value shots

    /// Photos whose Vision overall aesthetics score (-1 ... 1) falls below this are suggested
    /// for review, alongside anything Vision labels as a utility image.
    static let lowValueScoreThreshold: Float = -0.2

    // MARK: Analysis pipeline

    /// Side length of the local thumbnail requested for analysis.
    static let analysisThumbnailSize = 512
    /// Maximum images analyzed concurrently. Halved in Low Power Mode or serious thermal state.
    static let analysisConcurrency = 4
    /// Number of analysis results written to SwiftData per save.
    static let analysisBatchSize = 200

    // MARK: Swipe deck

    /// Fraction of card width a drag must pass to commit a swipe.
    static let swipeCommitFraction = 0.35
    /// Number of upcoming cards whose images are preloaded.
    static let deckPreloadCount = 5
}
