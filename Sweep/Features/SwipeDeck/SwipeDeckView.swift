import Photos
import SwiftUI

/// Tinder-style review of the library: swipe right to keep, left to mark for deletion.
/// Marked items are only deleted when the user taps Delete in the toolbar.
struct SwipeDeckView: View {
    let mediaType: DeckMediaType
    /// Shown when no card is up, e.g. while loading. Defaults to "Photos" / "Videos".
    var title: String?
    /// A curated, pre-ordered list to deal instead of the whole library.
    var source: (() async -> [String])?

    @Environment(PhotoLibraryService.self) private var library
    @State private var model = SwipeDeckModel()
    /// Drag offset of the top card.
    @State private var dragOffset: CGSize = .zero
    /// True while the top card is flying off screen, so gestures and buttons can't double-commit.
    @State private var isFlinging = false
    @State private var cardWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 24) {
            if model.isLoading {
                loadingView
            } else if model.isFinished {
                finishedView
            } else {
                deck
                controls
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .navigationTitle(progressTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canReorder {
                orderMenu
            }
            ToolbarItem(placement: .confirmationAction) {
                // Not mid-fling: the pending swipe would be dropped and its card would reappear.
                Button("Delete \(model.markedForDeletionCount)", role: .destructive) {
                    Task { await model.deleteMarked() }
                }
                .disabled(model.markedForDeletionCount == 0 || model.isDeleting || isFlinging)
            }
        }
        .overlay(alignment: .top) {
            if let result = model.lastCleanup {
                CleanupBanner(result: result, mediaType: mediaType)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring, value: model.lastCleanup)
        .task(id: model.lastCleanup?.id) {
            // Auto-dismiss the banner. A cancelled sleep means a newer banner replaced it.
            guard model.lastCleanup != nil, (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            model.lastCleanup = nil
        }
        .alert("Couldn’t Delete", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.load(mediaType, library: library, source: source) }
    }

    private var orderMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Order", selection: orderBinding) {
                    ForEach(DeckOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } label: {
                Label("Order", systemImage: "arrow.up.arrow.down")
            }
            .disabled(model.isLoading || model.isDeleting)
        }
    }

    private var orderBinding: Binding<DeckOrder> {
        Binding(
            get: { model.order },
            set: { newOrder in Task { await model.setOrder(newOrder) } }
        )
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let progress = library.sizeScanProgress, progress.total > 0 {
                Text("Measuring your library…")
                    .font(.subheadline.weight(.semibold))
                Text("\(progress.done, format: .number) of \(progress.total, format: .number)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var progressTitle: String {
        guard model.totalCount > 0, !model.isFinished else {
            return title ?? (mediaType == .photos ? "Photos" : "Videos")
        }
        return "\(model.currentIndex + 1) of \(model.totalCount)"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: Deck

    private var deck: some View {
        ZStack {
            // Reversed so the current card is drawn last, on top.
            ForEach(Array(model.visibleAssets.enumerated()).reversed(), id: \.element.localIdentifier) { position, asset in
                let isTop = position == 0
                SwipeCard(
                    asset: asset,
                    isTop: isTop,
                    image: model.images[asset.localIdentifier],
                    date: asset.creationDate,
                    fileSize: model.fileSize(of: asset),
                    videoDuration: asset.mediaType == .video ? asset.duration : nil,
                    dragProgress: isTop ? dragProgress : 0
                )
                .scaleEffect(1 - CGFloat(position) * 0.04)
                .offset(y: CGFloat(position) * 12)
                .offset(isTop ? dragOffset : .zero)
                .rotationEffect(.degrees(isTop ? Double(dragOffset.width / 20) : 0))
                .gesture(dragGesture, including: isTop ? .all : .subviews)
                .allowsHitTesting(isTop)
                .accessibilityHidden(!isTop)
                .accessibilityAction(named: "Keep") { fling(.keep) }
                .accessibilityAction(named: "Delete") { fling(.delete) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
    }

    /// -1 (fully toward delete) ... 1 (fully toward keep), reaching ±1 at the commit threshold.
    private var dragProgress: Double {
        let threshold = commitDistance
        guard threshold > 0 else { return 0 }
        return max(-1, min(1, dragOffset.width / threshold))
    }

    private var commitDistance: CGFloat {
        cardWidth * DetectionConfig.swipeCommitFraction
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isFlinging else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isFlinging else { return }
                // Use the predicted end so a quick flick commits even if it's short.
                let distance = value.predictedEndTranslation.width
                if distance > commitDistance {
                    fling(.keep)
                } else if distance < -commitDistance {
                    fling(.delete)
                } else {
                    withAnimation(.spring(duration: 0.3, bounce: 0.4)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    /// Animates the top card off screen, then records the decision.
    private func fling(_ decision: SwipeDecision) {
        guard !isFlinging, !model.isDeleting else { return }
        isFlinging = true
        let direction: CGFloat = decision == .keep ? 1 : -1
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: direction * cardWidth * 1.5, height: dragOffset.height)
        } completion: {
            // Reset without animation so the next card appears in place, not sliding back.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.swipe(decision)
                dragOffset = .zero
            }
            isFlinging = false
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 32) {
            DeckButton(title: "Delete", systemImage: "trash", tint: .red) {
                fling(.delete)
            }
            DeckButton(title: "Undo", systemImage: "arrow.uturn.backward", tint: .secondary, isSmall: true) {
                withAnimation(.spring) { model.undo() }
            }
            .disabled(!model.canUndo || isFlinging)
            DeckButton(title: "Keep", systemImage: "heart.fill", tint: .green) {
                fling(.keep)
            }
        }
        .disabled(model.isDeleting)
    }

    private var finishedView: some View {
        ContentUnavailableView {
            Label("All Caught Up", systemImage: "checkmark.circle")
        } description: {
            let marked = model.markedForDeletionCount
            let cleaned = model.sessionCleanup
            switch (mediaType, marked > 0, cleaned.itemCount > 0) {
            case (.photos, true, _):
                Text("Tap Delete to remove the ^[\(marked) photo](inflect: true) you marked.")
            case (.videos, true, _):
                Text("Tap Delete to remove the ^[\(marked) video](inflect: true) you marked.")
            case (.photos, false, true):
                Text("You deleted ^[\(cleaned.itemCount) photo](inflect: true), freeing \(cleaned.bytes, format: .byteCount(style: .file)).")
            case (.videos, false, true):
                Text("You deleted ^[\(cleaned.itemCount) video](inflect: true), freeing \(cleaned.bytes, format: .byteCount(style: .file)).")
            case (.photos, false, false):
                Text("You’ve reviewed every photo.")
            case (.videos, false, false):
                Text("You’ve reviewed every video.")
            }
        } actions: {
            if model.canUndo {
                Button("Undo Last Swipe") {
                    withAnimation(.spring) { model.undo() }
                }
            }
        }
    }
}

/// A single photo card with Keep/Delete stamps that fade in as it's dragged.
private struct SwipeCard: View {
    let asset: PHAsset
    let isTop: Bool
    let image: UIImage?
    let date: Date?
    let fileSize: Int64?
    /// Set for videos only; the card then shows a play glyph and the running time.
    let videoDuration: TimeInterval?
    let dragProgress: Double

    var body: some View {
        // Black letterboxing, like Photos: media is fitted whole, never cropped or stretched.
        Color.black
            .overlay {
                if let image {
                    if videoDuration != nil {
                        InlineVideoPlayer(asset: asset, poster: image, isActive: isTop)
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .bottom) {
                HStack {
                    if let date {
                        CardBadge(text: Text(date, format: .dateTime.day().month().year()))
                    }
                    Spacer()
                    if let videoDuration {
                        CardBadge(text: Text(formattedDuration(videoDuration)))
                    }
                    if let fileSize {
                        CardBadge(text: Text(fileSize, format: .byteCount(style: .file)))
                    }
                }
                .padding()
            }
            .overlay(alignment: .topLeading) {
                Stamp(title: "KEEP", tint: .green)
                    .rotationEffect(.degrees(-15))
                    .opacity(max(0, dragProgress))
                    .padding(24)
            }
            .overlay(alignment: .topTrailing) {
                Stamp(title: "DELETE", tint: .red)
                    .rotationEffect(.degrees(15))
                    .opacity(max(0, -dragProgress))
                    .padding(24)
            }
            .clipShape(.rect(cornerRadius: 24))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
            // .combine (not .ignore) so the video player's Play/Pause action reaches VoiceOver.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isImage)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }

    private var accessibilityText: Text {
        let kind = videoDuration == nil ? Text("Photo") : Text("Video")
        var label = if let date {
            Text("\(kind) from \(date, format: .dateTime.day().month().year())")
        } else {
            kind
        }
        if let videoDuration {
            let spoken = Duration.seconds(videoDuration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            label = Text("\(label), \(spoken)")
        }
        guard let fileSize else { return label }
        return Text("\(label), \(fileSize, format: .byteCount(style: .file))")
    }
}

/// Confirms a delete and how much space it frees. Shared with the group review screens.
struct CleanupBanner: View {
    let result: CleanupResult
    let mediaType: DeckMediaType

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Freed \(result.bytes, format: .byteCount(style: .file))")
                    .font(.headline)
                Group {
                    switch mediaType {
                    case .photos:
                        Text("^[\(result.itemCount) photo](inflect: true) moved to Recently Deleted. Space is fully reclaimed once it’s emptied.")
                    case .videos:
                        Text("^[\(result.itemCount) video](inflect: true) moved to Recently Deleted. Space is fully reclaimed once it’s emptied.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
    }
}

/// Small white-on-dim label pinned to the bottom of a card.
private struct CardBadge: View {
    let text: Text

    var body: some View {
        text
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.4), in: .capsule)
    }
}

private struct Stamp: View {
    let title: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(title)
            .font(.title.weight(.heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay {
                RoundedRectangle(cornerRadius: 8).stroke(tint, lineWidth: 4)
            }
    }
}

private struct DeckButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    var isSmall = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(isSmall ? .title3 : .title)
                .foregroundStyle(tint)
                .frame(width: isSmall ? 52 : 68, height: isSmall ? 52 : 68)
                .background(Color(.secondarySystemGroupedBackground), in: .circle)
                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        SwipeDeckView(mediaType: .photos)
    }
    .environment(PhotoLibraryService())
}
