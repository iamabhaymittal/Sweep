import SwiftUI

/// First-launch screen: one-line pitch and the Photos permission request.
struct OnboardingView: View {
    @Environment(PhotoLibraryService.self) private var library
    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 12) {
                Text("Sweep")
                    .font(.largeTitle.bold())
                Text("Find duplicates, blurry shots and large videos, then clear them with a swipe.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 12) {
                Label("Everything stays on this iPhone.", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    isRequesting = true
                    Task {
                        await library.requestAccess()
                        isRequesting = false
                    }
                } label: {
                    Text("Allow Photos Access")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRequesting)

                Text("Choose “Allow Full Access” so Sweep can check your whole library. Nothing is deleted without your review.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

#Preview {
    OnboardingView()
        .environment(PhotoLibraryService())
}
