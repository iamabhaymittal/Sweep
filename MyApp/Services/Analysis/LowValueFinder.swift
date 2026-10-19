import Foundation
import Photos

/// Picks out photos that are likely safe to delete: utility shots (receipts, documents,
/// whiteboards) and photos Vision scores as poor. Favorites are never suggested.
enum LowValueFinder {
    /// Worst first, so the most obvious candidates come up at the top of the deck.
    @concurrent
    nonisolated static func identifiers(from results: [AnalysisResult]) async -> [String] {
        let favorites = favoriteIdentifiers()
        return results
            .filter { result in
                guard !favorites.contains(result.assetID) else { return false }
                if result.isUtility == true { return true }
                guard let score = result.aestheticScore else { return false }
                return score < DetectionConfig.lowValueScoreThreshold
            }
            .sorted { ($0.aestheticScore ?? 0) < ($1.aestheticScore ?? 0) }
            .map(\.assetID)
    }

    nonisolated private static func favoriteIdentifiers() -> Set<String> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "isFavorite == YES")
        var identifiers = Set<String>()
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            identifiers.insert(asset.localIdentifier)
        }
        return identifiers
    }
}
