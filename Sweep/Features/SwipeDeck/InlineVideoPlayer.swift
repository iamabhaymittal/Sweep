import AVFoundation
import AVKit
import Observation
import Photos
import SwiftUI

/// Plays a library video inside its card. Tap to play or pause; the expand button opens a
/// full-screen player with scrubbing. Uses a bare AVPlayerLayer rather than VideoPlayer so the
/// card's swipe gesture keeps working, and `.resizeAspect` so the video is never cropped.
struct InlineVideoPlayer: View {
    let asset: PHAsset
    let poster: UIImage
    /// Only the top card plays; a card that stops being on top pauses.
    let isActive: Bool

    @State private var playback = VideoPlayback()
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            Image(uiImage: poster)
                .resizable()
                .scaledToFit()
            if let player = playback.player {
                PlayerLayerView(player: player)
            }
        }
        .contentShape(.rect)
        .onTapGesture { playback.toggle(asset) }
        .overlay {
            if playback.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else if !playback.isPlaying {
                Image(systemName: playback.failed ? "exclamationmark.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if playback.player != nil {
                VStack(alignment: .trailing, spacing: 12) {
                    ProgressView(value: playback.progress)
                        .tint(.white)
                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        isFullScreen = true
                    }
                    .labelStyle(.iconOnly)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.4), in: .circle)
                }
                .padding()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { playback.pause() }
        }
        .onDisappear {
            // Presenting the full-screen cover can also count as disappearing; keep playing then.
            if !isFullScreen { playback.pause() }
        }
        .fullScreenCover(isPresented: $isFullScreen) {
            if let player = playback.player {
                FullScreenVideo(player: player)
            }
        }
        .accessibilityAction(named: playback.isPlaying ? "Pause Video" : "Play Video") {
            playback.toggle(asset)
        }
    }
}

/// Owns the AVPlayer for one card and mirrors its state for the UI.
@Observable
final class VideoPlayback {
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var failed = false
    /// 0...1 through the video.
    private(set) var progress: Double = 0

    @ObservationIgnored private var timeObserver: Any?

    func toggle(_ asset: PHAsset) {
        if player != nil {
            isPlaying ? pause() : play()
            return
        }
        guard !isLoading else { return }
        isLoading = true
        failed = false
        Self.requestVideo(for: asset) { [weak self] handoff in
            Task { @MainActor in self?.didLoad(handoff.asset) }
        }
    }

    func play() {
        guard let player else { return }
        // .playback so sound plays even with the ring/silent switch set to silent, like Photos.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if progress >= 0.999 {
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    isolated deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }

    private func didLoad(_ avAsset: AVAsset?) {
        isLoading = false
        guard let avAsset else {
            failed = true
            return
        }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
        player.actionAtItemEnd = .pause
        // Fires periodically while playing and whenever playback starts or stops,
        // including when the full-screen player pauses or reaches the end.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.update(time)
            }
        }
        self.player = player
        play()
    }

    private func update(_ time: CMTime) {
        guard let player else { return }
        if let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 {
            progress = min(max(time.seconds / duration.seconds, 0), 1)
        }
        isPlaying = player.timeControlStatus != .paused
    }

    /// Nonisolated so PhotoKit can call the result handler from whichever queue it likes.
    nonisolated private static func requestVideo(
        for asset: PHAsset,
        completion: @escaping @Sendable (AssetHandoff) -> Void
    ) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        // Videos kept only in iCloud are streamed or downloaded on demand.
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
            completion(AssetHandoff(asset: avAsset))
        }
    }
}

/// Carries the AVAsset from PhotoKit's callback queue to the main actor. Unchecked because
/// AVAsset isn't Sendable; this is safe since PhotoKit hands it over once and never touches it again.
nonisolated private struct AssetHandoff: @unchecked Sendable {
    let asset: AVAsset?
}

/// Hosts an AVPlayerLayer so the video renders letterboxed, never cropped or stretched.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .clear
        view.playerLayer?.videoGravity = .resizeAspect
        view.playerLayer?.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer?.player = player
    }

    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    }
}

/// Full-screen system player with scrubbing, sharing the card's AVPlayer so position carries over.
private struct FullScreenVideo: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
                .background(.black)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
