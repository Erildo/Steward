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
        // The daily review, when iOS gives Steward a moment in the background.
        .backgroundTask(.appRefresh(ReviewRunner.taskID)) {
            await ReviewRunner.runInBackground()
        }
        // Errand check-ins, a few times a day (docs/adr/0003).
        .backgroundTask(.appRefresh(CheckIn.taskID)) {
            await CheckIn.run(inBackground: true)
        }
    }
}
