import SwiftUI
import LocalAuthentication

/// Face ID (or the passcode) in front of Steward, when the owner turns it on.
enum AppLock {
    static let storageKey = "app.locks"

    enum Outcome { case success, cancelled, unavailable(String) }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    static var systemImage: String { biometryName == "Touch ID" ? "touchid" : "faceid" }

    /// Face ID, falling back to the iPhone passcode.
    static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable("Set up \(biometryName) or a passcode in Settings first.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .cancelled
        } catch {
            return .cancelled
        }
    }
}

/// Covers the app until the owner unlocks it. Shown at launch and after
/// Steward has been in the background.
struct LockCover: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            StewardAvatar(size: 88, blinks: false)
            Text("Steward is locked")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Button("Unlock with \(AppLock.biometryName)", systemImage: AppLock.systemImage, action: unlock)
                .buttonStyle(.borderedProminent)
                .tint(Palette.orange)
                .foregroundStyle(Palette.onOrange)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
    }
}
