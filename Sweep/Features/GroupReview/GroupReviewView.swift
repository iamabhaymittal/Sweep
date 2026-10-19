import SwiftUI

/// Lists groups of near-identical photos with Sweep's suggested keeper in each and the rest
/// pre-marked for deletion. Tap a photo to flip it; long-press to see it large.
struct GroupReviewView: View {
    let title: LocalizedStringKey
    let emptyTitle: LocalizedStringKey
    let emptyMessage: LocalizedStringKey
    let scan: (PhotoLibraryService) async -> GroupScanResult

    @Environment(PhotoLibraryService.self) private var library
    @State private var model = GroupReviewModel()

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Looking through your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.groups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checkmark.circle", description: Text(emptyMessage))
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        summary
                        ForEach(model.groups) { group in
                            GroupCard(group: group, model: model)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Delete \(model.marked.count)", role: .destructive) {
                    Task { await model.deleteMarked(library: library) }
                }
                .disabled(model.marked.isEmpty || model.isDeleting)
            }
        }
        .overlay(alignment: .top) {
            if let result = model.lastCleanup {
                CleanupBanner(result: result, mediaType: .photos)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring, value: model.lastCleanup)
        .task(id: model.lastCleanup?.id) {
            guard model.lastCleanup != nil, (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            model.lastCleanup = nil
        }
        .alert("Couldn’t Delete", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.load { await scan(library) } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.markedBytes, format: .byteCount(style: .file)) can be freed")
                .font(.title2.bold())
                .contentTransition(.numericText())
            Text("^[\(model.marked.count) photo](inflect: true) marked in ^[\(model.groups.count) group](inflect: true). Tap a photo to keep or delete it; long-press to see it larger.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .animation(.default, value: model.markedBytes)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

/// One group: its photos in a horizontal strip, plus per-group shortcuts.
private struct GroupCard: View {
    let group: ReviewGroup
    let model: GroupReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if let date = group.date {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.headline)
                }
                Spacer()
                Text("^[\(group.assetIDs.count) photo](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(group.assetIDs, id: \.self) { id in
                        GroupThumbnail(
                            identifier: id,
                            isMarked: model.isMarked(id),
                            isSuggested: group.suggestedKeep.contains(id),
                            canMark: model.canMark(id, in: group)
                        ) {
                            withAnimation(.snappy) { model.toggle(id, in: group) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack {
                Text("Frees \(model.markedBytes(in: group), format: .byteCount(style: .file))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Menu("Options") {
                    Button("Use Suggestion", systemImage: "wand.and.stars") {
                        withAnimation(.snappy) { model.applySuggestion(in: group) }
                    }
                    Button("Keep All", systemImage: "checkmark.circle") {
                        withAnimation(.snappy) { model.keepAll(in: group) }
                    }
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }
}

private struct GroupThumbnail: View {
    let identifier: String
    let isMarked: Bool
    let isSuggested: Bool
    let canMark: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            AssetThumbnailView(identifier: identifier)
                .frame(width: 104, height: 140)
                .overlay {
                    if isMarked {
                        Color.red.opacity(0.25)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isMarked ? "trash.circle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isMarked ? Color.red : Color.green)
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if isSuggested {
                        Label("Best", systemImage: "star.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.5), in: .capsule)
                            .padding(6)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isMarked ? Color.red : Color.clear, lineWidth: 3)
                }
        }
        .buttonStyle(.plain)
        // Not .disabled: that would dim the group's keeper. The model ignores the tap instead,
        // and the accessibility hint explains why.
        .contextMenu {
            Button(isMarked ? "Keep" : "Delete", systemImage: isMarked ? "checkmark.circle" : "trash", action: toggle)
                .disabled(!isMarked && !canMark)
        } preview: {
            AssetThumbnailView(identifier: identifier, pixelSize: 1600)
                .frame(width: 360, height: 480)
        }
        .accessibilityLabel(isSuggested ? "Suggested photo" : "Photo")
        .accessibilityValue(isMarked ? "Marked for deletion" : "Kept")
        .accessibilityHint(!isMarked && !canMark ? "The last kept photo in a group can’t be deleted." : "Double-tap to toggle.")
    }
}
