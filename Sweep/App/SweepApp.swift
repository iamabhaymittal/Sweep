import SwiftData
import SwiftUI

@main
struct SweepApp: App {
    @State private var library = PhotoLibraryService()
    @State private var analysis = AnalysisService(container: SweepApp.makeContainer())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(analysis)
        }
    }

    /// Falls back to an in-memory store if the on-disk one can't be opened (e.g. disk full), and to
    /// no analysis at all if even that fails, so a storage problem never stops the app launching.
    private static func makeContainer() -> ModelContainer? {
        if let container = try? ModelContainer(for: PhotoAnalysis.self) {
            return container
        }
        return try? ModelContainer(
            for: PhotoAnalysis.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
