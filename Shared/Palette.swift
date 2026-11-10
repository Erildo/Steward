import SwiftUI
import UIKit

/// Steward's colours. White by default, with a dark theme the owner can choose.
enum Palette {
    static let ground = dynamic(light: 0xFFFFFF, dark: 0x0B0D12)
    static let ink = dynamic(light: 0x1C1C1E, dark: 0xF2F0EA)
    static let stewardBubble = dynamic(light: 0xEDEDF0, dark: 0x1C2029)
    static let muted = dynamic(light: 0x6C6C70, dark: 0xA0A6B4)
    /// Primary. Only on your words, the current tab, send and the focus ring.
    static let orange = dynamic(light: 0xF15A29, dark: 0xF15A29)
    static let onOrange = dynamic(light: 0x1F0D05, dark: 0x1F0D05)

    static let bubbleRadius: CGFloat = 19
    static let cardRadius: CGFloat = 16

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "White"
        case .dark: "Dark"
        case .system: "Match iPhone"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

/// Steward's avatar: the house stays yours.
struct StewardAvatar: View {
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: "house.fill")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(Palette.onOrange)
            .frame(width: size, height: size)
            .background(Palette.orange, in: .circle)
            .accessibilityHidden(true)
    }
}
