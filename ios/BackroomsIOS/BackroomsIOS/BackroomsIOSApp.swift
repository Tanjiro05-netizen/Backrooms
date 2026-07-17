import SwiftUI

@main
struct BackroomsIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            GameContainerView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}
