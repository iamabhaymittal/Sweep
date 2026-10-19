import SwiftUI
import UIKit

/// Dashboard root: storage, library counts, and entry points into the swipe decks.
struct HomeView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(AnalysisService.self) private var analysis
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if library.access == .limited {
                        LimitedAccessBanner()
                    }
                    StorageCard(
                        device: library.deviceStorage,
                        sizes: library.sizeIndex,
                        scanProgress: library.sizeScanProgress,
                        cleanup: library.cleanupTotals
                    )
                    LibraryBreakdownCard(counts: library.counts)
                    NavigationLink {
                        SwipeDeckView(mediaType: .photos)
                    } label: {
                        SwipeDeckEntryCard(
                            title: "Swipe Photos",
                            subtitle: "Keep or delete photos, largest first",
                            systemImage: "photo.stack",
                            tint: .pink
                        )
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        SwipeDeckView(mediaType: .videos)
                    } label: {
                        SwipeDeckEntryCard(
                            title: "Swipe Videos",
                            subtitle: "Keep or delete videos, largest first",
                            systemImage: "film.stack",
                            tint: .purple
                        )
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        GroupReviewView(
                            title: "Bursts",
                            emptyTitle: "No Bursts",
                            emptyMessage: "Burst photos you take will show up here.",
                            scan: { _ in await BurstFinder.find() }
                        )
                    } label: {
                        SwipeDeckEntryCard(
                            title: "Bursts",
                            subtitle: "Keep the best shot, delete the hidden extras",
                            systemImage: "square.stack.3d.down.right",
                            tint: .orange
                        )
                    }
                    .buttonStyle(.plain)

                    if let progress = analysis.progress {
                        AnalysisStatusCard(progress: progress)
                    }
                    NavigationLink {
                        SwipeDeckView(mediaType: .photos, title: "Low-Value Shots") {
                            await LowValueFinder.identifiers(from: analysis.results())
                        }
                    } label: {
                        SwipeDeckEntryCard(
                            title: "Low-Value Shots",
                            subtitle: "Receipts, documents and poor shots, worst first",
                            systemImage: "doc.text.image",
                            tint: .teal
                        )
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        GroupReviewView(
                            title: "Duplicates",
                            emptyTitle: "No Duplicates",
                            emptyMessage: analysis.isRunning
                                ? "None found yet. Sweep is still analyzing your library, so check back soon."
                                : "No duplicate photos found in your library.",
                            scan: { library in
                                async let sizes = library.loadSizes()
                                async let results = analysis.results()
                                return await DuplicateFinder.find(in: results, sizes: sizes.sizes)
                            }
                        )
                    } label: {
                        SwipeDeckEntryCard(
                            title: "Duplicates",
                            subtitle: "Identical and near-identical copies",
                            systemImage: "plus.square.on.square",
                            tint: .indigo
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Sweep")
            .task {
                await refresh()
            }
            .refreshable {
                await refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                // Free space changes while the app is in the background, and new photos
                // may have been taken that need analyzing.
                if phase == .active {
                    library.refreshDeviceStorage()
                    analysis.start()
                }
            }
        }
    }

    private func refresh() async {
        analysis.start()
        library.refreshDeviceStorage()
        async let counts: Void = library.loadCounts()
        async let sizes = library.loadSizes()
        _ = await (counts, sizes)
    }
}

/// Explains that results only cover the photos the user selected.
private struct LimitedAccessBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Limited Access", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Sweep can only see the photos you selected, so results won’t cover your whole library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Change Access in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 20))
    }
}

/// Total item count plus a tile per media category.
private struct LibraryBreakdownCard: View {
    let counts: LibraryCounts?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(counts?.total ?? 0) items")
                    .font(.largeTitle.bold())
                    .contentTransition(.numericText())
            }

            LazyVGrid(columns: columns, spacing: 12) {
                CountTile(title: "Photos", systemImage: "photo", tint: .blue, value: counts?.photos)
                CountTile(title: "Videos", systemImage: "video", tint: .purple, value: counts?.videos)
                CountTile(title: "Screenshots", systemImage: "camera.viewfinder", tint: .teal, value: counts?.screenshots)
                CountTile(title: "Live Photos", systemImage: "livephoto", tint: .orange, value: counts?.livePhotos)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .redacted(reason: counts == nil ? .placeholder : [])
        .animation(.spring, value: counts)
    }
}

/// Shown while photos are being analyzed, since Low-Value Shots and Duplicates fill in as it runs.
private struct AnalysisStatusCard: View {
    let progress: ScanProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Analyzing your photos", systemImage: "sparkle.magnifyingglass")
                .font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text("\(progress.done, format: .number) of \(progress.total, format: .number). Low-Value Shots and Duplicates fill in as this runs. It happens on this iPhone and continues next time if you leave.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// Entry point into a keep/delete swipe deck.
private struct SwipeDeckEntryCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .contentShape(.rect)
    }
}

private struct CountTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
            Text(value ?? 0, format: .number)
                .font(.title2.bold())
                .contentTransition(.numericText())
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HomeView()
        .environment(PhotoLibraryService())
        .environment(AnalysisService(container: nil))
}
