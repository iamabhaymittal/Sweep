import Foundation
import SwiftData

/// Persisted analysis of one photo. Nonisolated so the store actor can use it off the main actor.
@Model
nonisolated final class PhotoAnalysis {
    @Attribute(.unique) var assetID: String
    /// The asset's modification date when analyzed; a different date means the photo was edited.
    var modificationDate: Date
    /// 64-bit difference hash, stored by bit pattern.
    var dHash: Int64
    /// Vision's overall aesthetics score, -1 (worst) ... 1 (best). Nil if Vision couldn't score it.
    var aestheticScore: Float?
    /// Vision's "utility" label: receipts, documents, screenshots of text and the like.
    var isUtility: Bool?

    init(_ result: AnalysisResult) {
        assetID = result.assetID
        modificationDate = result.modificationDate
        dHash = Int64(bitPattern: result.dHash)
        aestheticScore = result.aestheticScore
        isUtility = result.isUtility
    }
}

/// A Sendable copy of an analysis, for passing between actors.
nonisolated struct AnalysisResult: Sendable {
    let assetID: String
    let modificationDate: Date
    let dHash: UInt64
    let aestheticScore: Float?
    let isUtility: Bool?
}

/// Owns all SwiftData reads and writes for analysis, off the main actor.
@ModelActor
actor AnalysisStore {
    func modificationDates() throws -> [String: Date] {
        let records = try modelContext.fetch(FetchDescriptor<PhotoAnalysis>())
        return Dictionary(records.map { ($0.assetID, $0.modificationDate) }, uniquingKeysWith: { _, new in new })
    }

    /// Inserting a record whose unique `assetID` already exists updates it in place.
    func upsert(_ results: [AnalysisResult]) throws {
        guard !results.isEmpty else { return }
        for result in results {
            modelContext.insert(PhotoAnalysis(result))
        }
        try modelContext.save()
    }

    func delete(_ identifiers: [String]) throws {
        guard !identifiers.isEmpty else { return }
        try modelContext.delete(model: PhotoAnalysis.self, where: #Predicate { identifiers.contains($0.assetID) })
        try modelContext.save()
    }

    func allResults() throws -> [AnalysisResult] {
        try modelContext.fetch(FetchDescriptor<PhotoAnalysis>()).map {
            AnalysisResult(
                assetID: $0.assetID,
                modificationDate: $0.modificationDate,
                dHash: UInt64(bitPattern: $0.dHash),
                aestheticScore: $0.aestheticScore,
                isUtility: $0.isUtility
            )
        }
    }
}
