import SwiftUI

@main
struct StewardApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG && targetEnvironment(simulator)
        // Debug runs in the Simulator open with every tab's sample data. A
        // `-uiState` launch argument still wins; `-uiState none` gives real,
        // empty files. On a phone, debug builds run for real, like release:
        // the owner's own mailbox, AI key and files (`-uiState demo` for samples).
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
