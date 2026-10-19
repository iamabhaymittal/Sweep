import Foundation
import Photos

/// Groups photos whose difference hashes are within `DetectionConfig.duplicateHammingDistance`
/// bits of each other, and suggests one keeper per group.
enum DuplicateFinder {
    @concurrent
    nonisolated static func find(in results: [AnalysisResult], sizes: [String: Int64]) async -> GroupScanResult {
        // A hash of all zeros or all ones means a flat image (black frames, blank screens).
        // Those all "match" each other without being duplicates, so leave them out.
        let candidates = results.filter { $0.dHash != 0 && $0.dHash != .max }
        let components = clusters(of: candidates.map(\.dHash), maxDistance: DetectionConfig.duplicateHammingDistance)
        guard !Task.isCancelled else { return GroupScanResult() }

        let groupedIDs = components.map { $0.map { candidates[$0].assetID } }
        let assets = fetchAssets(groupedIDs.flatMap { $0 })

        var scan = GroupScanResult()
        for ids in groupedIDs {
            // Photos deleted since they were analyzed won't fetch; drop them.
            let members = ids.compactMap { assets[$0] }
            guard members.count > 1, let best = bestPhoto(in: members, sizes: sizes) else { continue }
            let ordered = [best] + members.filter { $0 != best }.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            for asset in ordered {
                if let size = sizes[asset.localIdentifier] {
                    scan.sizes[asset.localIdentifier] = size
                }
            }
            scan.groups.append(ReviewGroup(
                id: best.localIdentifier,
                assetIDs: ordered.map(\.localIdentifier),
                suggestedKeep: [best.localIdentifier],
                date: members.compactMap(\.creationDate).min()
            ))
        }
        scan.sortByReclaimableBytes()
        return scan
    }

    /// Connected components of "within maxDistance bits", as index lists of size ≥ 2.
    ///
    /// Pigeonhole: split the 64 bits into maxDistance + 1 chunks. Two hashes that differ in at most
    /// maxDistance bits must agree exactly on at least one chunk, so only hashes sharing a chunk
    /// value need comparing. That turns an all-pairs comparison into a handful of small buckets.
    nonisolated static func clusters(of hashes: [UInt64], maxDistance: Int) -> [[Int]] {
        var parent = Array(hashes.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        let chunkCount = maxDistance + 1
        let chunkWidth = 64 / chunkCount
        for chunk in 0..<chunkCount {
            let shift = chunk * chunkWidth
            // The last chunk takes any leftover bits.
            let width = chunk == chunkCount - 1 ? 64 - shift : chunkWidth
            let mask: UInt64 = width == 64 ? .max : (1 << UInt64(width)) - 1

            var buckets: [UInt64: [Int]] = [:]
            for (index, hash) in hashes.enumerated() {
                buckets[(hash >> UInt64(shift)) & mask, default: []].append(index)
            }
            for bucket in buckets.values where bucket.count > 1 {
                for i in bucket.indices {
                    for j in bucket.indices where j > i {
                        let a = bucket[i], b = bucket[j]
                        guard (hashes[a] ^ hashes[b]).nonzeroBitCount <= maxDistance else { continue }
                        let rootA = root(a), rootB = root(b)
                        if rootA != rootB { parent[rootB] = rootA }
                    }
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for index in hashes.indices {
            groups[root(index), default: []].append(index)
        }
        return groups.values.filter { $0.count > 1 }
    }

    /// Favorites win, then the highest resolution, then the biggest file (least compressed),
    /// then the oldest, which is most likely the original rather than a saved copy.
    nonisolated private static func bestPhoto(in assets: [PHAsset], sizes: [String: Int64]) -> PHAsset? {
        assets.max { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return rhs.isFavorite }
            let lhsPixels = lhs.pixelWidth * lhs.pixelHeight
            let rhsPixels = rhs.pixelWidth * rhs.pixelHeight
            if lhsPixels != rhsPixels { return lhsPixels < rhsPixels }
            let lhsSize = sizes[lhs.localIdentifier] ?? 0
            let rhsSize = sizes[rhs.localIdentifier] ?? 0
            if lhsSize != rhsSize { return lhsSize < rhsSize }
            return (lhs.creationDate ?? .distantPast) > (rhs.creationDate ?? .distantPast)
        }
    }

    nonisolated private static func fetchAssets(_ identifiers: [String]) -> [String: PHAsset] {
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
        }
        return assets
    }
}
