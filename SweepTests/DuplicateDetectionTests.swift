import CoreGraphics
import Testing
@testable import Sweep

/// Difference hashing and duplicate clustering.
struct DuplicateDetectionTests {
    // MARK: Difference hash

    @Test func identicalImagesHashIdentically() throws {
        let a = try #require(ImageAnalyzer.differenceHash(of: makeImage(width: 512, height: 384)))
        let b = try #require(ImageAnalyzer.differenceHash(of: makeImage(width: 512, height: 384)))
        #expect(a == b)
    }

    @Test func resizedCopyStaysWithinDuplicateThreshold() throws {
        let original = try #require(ImageAnalyzer.differenceHash(of: makeImage(width: 512, height: 384)))
        let resized = try #require(ImageAnalyzer.differenceHash(of: makeImage(width: 200, height: 150)))
        #expect((original ^ resized).nonzeroBitCount <= DetectionConfig.duplicateHammingDistance)
    }

    @Test func differentImagesAreFarApart() throws {
        let a = try #require(ImageAnalyzer.differenceHash(of: makeImage(width: 512, height: 384)))
        let b = try #require(ImageAnalyzer.differenceHash(of: makeImage(width: 512, height: 384, variant: .bar)))
        #expect((a ^ b).nonzeroBitCount > DetectionConfig.duplicateHammingDistance)
    }

    // MARK: Clustering

    @Test func clustersMatchBruteForce() {
        var rng = SplitMix64(seed: 42)
        var hashes = (0..<2000).map { _ in rng.next() }
        // Plant near-duplicates of the first 200 hashes, each 0–3 bits away.
        for index in 0..<200 {
            var hash = hashes[index]
            for _ in 0..<Int(rng.next() % 4) {
                hash ^= 1 << (rng.next() % 64)
            }
            hashes.append(hash)
        }

        let fast = Set(DuplicateFinder.clusters(of: hashes, maxDistance: 3).map(Set.init))
        #expect(fast == bruteForceClusters(hashes, maxDistance: 3))
        #expect(fast.count >= 200)
    }

    @Test func distanceThresholdIsInclusive() {
        let base: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        let threeBitsAway = base ^ 0b111
        let fourBitsAway = base ^ 0b1111

        #expect(DuplicateFinder.clusters(of: [base, threeBitsAway], maxDistance: 3).count == 1)
        #expect(DuplicateFinder.clusters(of: [base, fourBitsAway], maxDistance: 3).isEmpty)
    }

    @Test func groupingIsTransitive() {
        // a–b and b–c are each 2 bits apart; a–c is 4 apart. All three belong together.
        let a: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
        let b = a ^ 0b11
        let c = b ^ 0b1100
        let clusters = DuplicateFinder.clusters(of: [a, b, c], maxDistance: 3)
        #expect(clusters.map(Set.init) == [[0, 1, 2]])
    }

    @Test func singletonsAreNotReturned() {
        #expect(DuplicateFinder.clusters(of: [0x1, 0xFFFF_0000_0000_0000], maxDistance: 3).isEmpty)
        #expect(DuplicateFinder.clusters(of: [], maxDistance: 3).isEmpty)
    }

    // MARK: Helpers

    private enum Variant { case circle, bar }

    /// A gradient with a white shape, rendered at any size.
    private func makeImage(width: Int, height: Int, variant: Variant = .circle) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let colors = [CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1), CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
        let w = CGFloat(width), h = CGFloat(height)
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        switch variant {
        case .circle:
            context.fillEllipse(in: CGRect(x: w * 0.2, y: h * 0.3, width: w * 0.3, height: h * 0.3))
        case .bar:
            context.fill(CGRect(x: w * 0.6, y: h * 0.1, width: w * 0.2, height: h * 0.7))
        }
        return context.makeImage()!
    }

    private func bruteForceClusters(_ hashes: [UInt64], maxDistance: Int) -> Set<Set<Int>> {
        var parent = Array(hashes.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        for a in hashes.indices {
            for b in hashes.indices where b > a && (hashes[a] ^ hashes[b]).nonzeroBitCount <= maxDistance {
                let rootA = root(a), rootB = root(b)
                if rootA != rootB { parent[rootB] = rootA }
            }
        }
        var groups: [Int: Set<Int>] = [:]
        for index in hashes.indices { groups[root(index), default: []].insert(index) }
        return Set(groups.values.filter { $0.count > 1 })
    }
}

/// Small deterministic PRNG so test data is identical on every run.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
