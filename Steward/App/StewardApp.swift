import SwiftUI

@main
struct StewardApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        // Debug builds open with every tab's sample data, so a phone run from
        // Xcode, or reopened from the Home Screen, has something to try. A
        // `-uiState` launch argument still wins; `-uiState none` gives the
        // owner's real, empty files. Release builds never see this.
        UserDefaults.standard.register(defaults: ["uiState": "demo"])
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
