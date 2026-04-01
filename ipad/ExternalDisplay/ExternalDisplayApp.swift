IPimport SwiftUI

@main
struct ExternalDisplayApp: App {
    var body: some Scene {
        WindowGroup {
            ScreenReceiverView()
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
