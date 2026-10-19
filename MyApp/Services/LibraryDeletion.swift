import Photos

/// Deletes assets from the library. Photos shows its own confirmation alert, and deleted
/// items move to Recently Deleted for 30 days.
enum LibraryDeletion {
    /// Returns false if the user cancelled the system confirmation; throws on any other failure.
    static func delete(_ identifiers: [String]) async throws -> Bool {
        guard !identifiers.isEmpty else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges(changes(deleting: identifiers))
            return true
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return false
        }
    }

    /// Built in a nonisolated context so the block isn't inferred as main-actor isolated:
    /// PhotoKit runs it on its own transaction queue, where a main-actor check would trap.
    nonisolated private static func changes(deleting identifiers: [String]) -> @Sendable () -> Void {
        {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
