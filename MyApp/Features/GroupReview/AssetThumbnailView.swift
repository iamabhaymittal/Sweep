import Photos
import SwiftUI
import UIKit

/// Loads and shows one library photo by identifier, fitted whole (never cropped) on black.
struct AssetThumbnailView: View {
    let identifier: String
    /// Longest side of the requested image, in pixels.
    var pixelSize: CGFloat = 400

    @State private var image: UIImage?

    var body: some View {
        Color.black
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .task(id: identifier) {
                image = await Self.loadImage(identifier, pixelSize: pixelSize)
            }
    }

    /// Off the main actor so PhotoKit's result handler isn't treated as main-actor code.
    @concurrent
    nonisolated private static func loadImage(_ identifier: String, pixelSize: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        // One callback only, so the continuation is resumed exactly once.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: pixelSize, height: pixelSize),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
