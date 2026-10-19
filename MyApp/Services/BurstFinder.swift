import Foundation
import Photos

/// Finds burst sequences and suggests which frame of each to keep.
///
/// Photos only surfaces a burst's cover and the user's picks; every other frame is hidden
/// unless a fetch sets `includeAllBurstAssets`. That's also why those frames don't show up in
/// the library size scan: this is storage most people don't know they're using.
enum BurstFinder {
    @concurrent
    nonisolated static func find() async -> GroupScanResult {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        // Reading burstIdentifier is cheap, so filter here rather than with a fetch predicate.
        var bursts: [String: [PHAsset]] = [:]
        var order: [String] = []
        result.enumerateObjects { asset, _, _ in
            guard let burstID = asset.burstIdentifier else { return }
            if bursts[burstID] == nil { order.append(burstID) }
            bursts[burstID, default: []].append(asset)
        }

        var scan = GroupScanResult()
        for burstID in order {
            if Task.isCancelled { return GroupScanResult() }
            guard let frames = bursts[burstID], frames.count > 1 else { continue }
            for frame in frames {
                if let size = PhotoLibraryService.fileSize(of: frame) {
                    scan.sizes[frame.localIdentifier] = size
                }
            }
            scan.groups.append(ReviewGroup(
                id: burstID,
                assetIDs: frames.map(\.localIdentifier),
                suggestedKeep: suggestedKeep(in: frames),
                date: frames.first?.creationDate
            ))
        }
        scan.sortByReclaimableBytes()
        return scan
    }

    /// The user's own picks if they made any; otherwise the cover frame Photos chose, which is
    /// its best-shot guess. Auto-picks alone can mark several frames, so they're only a fallback.
    nonisolated private static func suggestedKeep(in frames: [PHAsset]) -> Set<String> {
        let userPicks = frames.filter { $0.burstSelectionTypes.contains(.userPick) }
        if !userPicks.isEmpty {
            return Set(userPicks.map(\.localIdentifier))
        }
        let best = frames.first(where: \.representsBurst)
            ?? frames.first { $0.burstSelectionTypes.contains(.autoPick) }
            ?? frames[0]
        return [best.localIdentifier]
    }
}
