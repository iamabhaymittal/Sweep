import SwiftUI

/// Routes to onboarding, the access-denied state, or Home based on Photos authorization.
struct RootView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch library.access {
            case .notDetermined:
                OnboardingView()
            case .denied:
                AccessDeniedView()
            case .limited, .full:
                HomeView()
            }
        }
        .animation(.default, value: library.access)
        .onChange(of: scenePhase) { _, phase in
            // The user may have changed access in Settings while the app was in the background.
            if phase == .active {
                library.refreshAccess()
            }
        }
    }
}
