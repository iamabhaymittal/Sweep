import SwiftUI

/// Device free space as a meter, then how much of it the library takes and what Sweep has cleaned.
struct StorageCard: View {
    let device: DeviceStorage?
    let sizes: LibrarySizeIndex?
    let scanProgress: ScanProgress?
    let cleanup: CleanupTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let device {
                    Text("\(device.available, format: .byteCount(style: .file)) free")
                        .font(.largeTitle.bold())
                        .contentTransition(.numericText())
                    Text("\(device.used, format: .byteCount(style: .file)) of \(device.total, format: .byteCount(style: .file)) used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unavailable")
                        .font(.largeTitle.bold())
                }
            }

            if let device, device.total > 0 {
                StorageMeter(fraction: Double(device.used) / Double(device.total))
                    .accessibilityElement()
                    .accessibilityLabel("Storage used")
                    .accessibilityValue(Text(Double(device.used) / Double(device.total), format: .percent.precision(.fractionLength(0))))
            }

            VStack(spacing: 0) {
                Group {
                    StorageRow(title: "Photos", systemImage: "photo", tint: .blue, bytes: sizes?.photoBytes)
                    Divider().padding(.leading, 40)
                    StorageRow(title: "Videos", systemImage: "video", tint: .purple, bytes: sizes?.videoBytes)
                }
                .redacted(reason: sizes == nil ? .placeholder : [])
                Divider().padding(.leading, 40)
                StorageRow(title: "Cleaned with Sweep", systemImage: "sparkles", tint: .green, bytes: cleanup.bytes)
            }

            footnote
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .animation(.spring, value: device)
    }

    @ViewBuilder
    private var footnote: some View {
        if sizes == nil, let scanProgress, scanProgress.total > 0 {
            Text("Measuring library… \(scanProgress.done, format: .number) of \(scanProgress.total, format: .number)")
                .monospacedDigit()
        } else {
            // fileSize reports full originals even when only an optimized copy is on the device.
            Text("Photo and video sizes include originals stored in iCloud. Deleted items free space once Recently Deleted is emptied.")
        }
    }
}

/// A single-series capacity bar: used space against the remaining track.
private struct StorageMeter: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color(.tertiarySystemFill))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 12)
    }
}

private struct StorageRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let bytes: Int64?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 28)
            Text(title)
            Spacer()
            Text(bytes ?? 0, format: .byteCount(style: .file))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    StorageCard(
        device: DeviceStorage(total: 128_000_000_000, available: 31_500_000_000),
        sizes: LibrarySizeIndex(photoBytes: 18_200_000_000, videoBytes: 41_700_000_000),
        scanProgress: nil,
        cleanup: CleanupTotals(itemCount: 42, bytes: 2_300_000_000)
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
