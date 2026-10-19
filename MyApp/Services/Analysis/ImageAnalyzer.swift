import CoreGraphics
import Foundation
import ImageIO
import Photos
import UIKit
import Vision

/// Analyzes a single photo: a difference hash for duplicate detection and Vision's
/// aesthetics scores for spotting low-value shots.
enum ImageAnalyzer {
    @concurrent
    nonisolated static func analyze(_ assetID: String, modificationDate: Date) async -> AnalysisResult? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let image = await thumbnail(for: asset),
              let cgImage = image.cgImage,
              let hash = differenceHash(of: cgImage)
        else { return nil }

        // Vision isn't available everywhere (some Simulators, for one); keep the hash regardless.
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let scores = try? await CalculateImageAestheticsScoresRequest().perform(on: cgImage, orientation: orientation)

        return AnalysisResult(
            assetID: assetID,
            modificationDate: modificationDate,
            dHash: hash,
            aestheticScore: scores?.overallScore,
            isUtility: scores?.isUtility
        )
    }

    /// A local thumbnail only. Downloading thousands of iCloud originals just to analyze them would
    /// burn data and battery; photos without a local thumbnail are retried on a later run.
    nonisolated private static func thumbnail(for asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        // One callback only, so the continuation is resumed exactly once.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let side = CGFloat(DetectionConfig.analysisThumbnailSize)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// dHash: shrink to 9×8 grayscale and record, for each row, whether each pixel is brighter
    /// than its right-hand neighbour. Re-encodes, resizes and small edits barely change the 64 bits,
    /// so near-identical photos land within a few bits of each other.
    nonisolated static func differenceHash(of image: CGImage) -> UInt64? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var hash: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                hash <<= 1
                if pixels[row * width + column] > pixels[row * width + column + 1] {
                    hash |= 1
                }
            }
        }
        return hash
    }
}

nonisolated extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
