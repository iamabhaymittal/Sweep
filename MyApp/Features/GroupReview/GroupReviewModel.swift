import Foundation
import Observation

/// A set of near-identical photos, such as a burst or a run of duplicates.
/// Nonisolated: the finders build these off the main actor.
nonisolated struct ReviewGroup: Identifiable, Equatable, Sendable {
    let id: String
    /// Display order, e.g. capture order for a burst.
    var assetIDs: [String]
    /// What Sweep recommends keeping; everything else starts out marked for deletion.
    var suggestedKeep: Set<String>
    let date: Date?
}

/// The output of a group finder: the groups plus the size of every photo in them.
nonisolated struct GroupScanResult: Sendable {
    var groups: [ReviewGroup] = []
    var sizes: [String: Int64] = [:]

    /// Biggest wins first.
    mutating func sortByReclaimableBytes() {
        let sizes = sizes
        func reclaimable(_ group: ReviewGroup) -> Int64 {
            group.assetIDs.filter { !group.suggestedKeep.contains($0) }.compactMap { sizes[$0] }.reduce(0, +)
        }
        groups.sort { reclaimable($0) > reclaimable($1) }
    }
}

/// Drives a group review screen: holds the groups, which photos are marked, and deletes them.
/// Every group always keeps at least one photo; the UI can't mark the last one.
@Observable
final class GroupReviewModel {
    private(set) var groups: [ReviewGroup] = []
    private(set) var marked: Set<String> = []
    private(set) var isLoading = true
    private(set) var isDeleting = false
    var lastCleanup: CleanupResult?
    var errorMessage: String?

    @ObservationIgnored private var sizes: [String: Int64] = [:]
    @ObservationIgnored private var hasLoaded = false

    var markedBytes: Int64 { marked.compactMap { sizes[$0] }.reduce(0, +) }

    func size(of id: String) -> Int64? { sizes[id] }

    func markedBytes(in group: ReviewGroup) -> Int64 {
        group.assetIDs.filter(marked.contains).compactMap { sizes[$0] }.reduce(0, +)
    }

    // MARK: Loading

    func load(_ scan: () async -> GroupScanResult) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        let result = await scan()
        sizes = result.sizes
        groups = result.groups
        marked = Set(result.groups.flatMap { group in
            group.assetIDs.filter { !group.suggestedKeep.contains($0) }
        })
        isLoading = false
    }

    // MARK: Selection

    func isMarked(_ id: String) -> Bool { marked.contains(id) }

    /// Marking is refused when it would leave the group with nothing kept.
    func canMark(_ id: String, in group: ReviewGroup) -> Bool {
        marked.contains(id) || group.assetIDs.count { !marked.contains($0) } > 1
    }

    func toggle(_ id: String, in group: ReviewGroup) {
        if marked.contains(id) {
            marked.remove(id)
        } else if canMark(id, in: group) {
            marked.insert(id)
        }
    }

    func keepAll(in group: ReviewGroup) {
        marked.subtract(group.assetIDs)
    }

    func applySuggestion(in group: ReviewGroup) {
        keepAll(in: group)
        marked.formUnion(group.assetIDs.filter { !group.suggestedKeep.contains($0) })
    }

    // MARK: Deleting

    func deleteMarked(library: PhotoLibraryService) async {
        let identifiers = Array(marked)
        guard !identifiers.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }

        do {
            guard try await LibraryDeletion.delete(identifiers) else { return }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let result = CleanupResult(itemCount: identifiers.count, bytes: markedBytes)
        lastCleanup = result
        library.recordCleanup(itemCount: result.itemCount, bytes: result.bytes)

        // Drop deleted photos, then any group with nothing left to compare.
        let deleted = marked
        marked.removeAll()
        groups = groups.compactMap { group in
            var group = group
            group.assetIDs.removeAll { deleted.contains($0) }
            group.suggestedKeep.subtract(deleted)
            return group.assetIDs.count > 1 ? group : nil
        }
    }
}
