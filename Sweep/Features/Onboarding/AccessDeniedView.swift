import SwiftUI
import UIKit

/// Shown when Photos access is denied or restricted.
struct AccessDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Photos Access Needed", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Sweep needs access to your photo library to find items worth deleting. Everything is analyzed on this iPhone.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    AccessDeniedView()
}
