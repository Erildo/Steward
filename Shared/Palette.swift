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

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
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

/// Steward's avatar: a cat. Independent, unbothered by companies, and on your side.
/// It blinks now and then in the app; widgets pass `blinks: false`.
struct StewardAvatar: View {
    var size: CGFloat = 30
    var blinks = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var eyeOpen: CGFloat = 1

    var body: some View {
        CatShape(eyeOpen: eyeOpen, small: size < 40)
            .fill(Palette.onOrange)
            .frame(width: size * 0.64, height: size * 0.64)
            .offset(y: size * 0.02)
            .frame(width: size, height: size)
            .background(Palette.orange, in: .circle)
            .accessibilityHidden(true)
            .task(id: blinks && !reduceMotion) {
                guard blinks, !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 3.5...7)))
                    withAnimation(.easeIn(duration: 0.07)) { eyeOpen = 0.12 }
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeOut(duration: 0.1)) { eyeOpen = 1 }
                }
            }
    }
}

/// The cat's head as one shape: ears joined to a round face, with the eyes cut
/// out so the avatar's orange shows through. One shape means no seams, even
/// under Liquid Glass, which treats overlapping layers separately.
nonisolated private struct CatShape: Shape {
    /// 1 is open, near 0 is a blink.
    var eyeOpen: CGFloat
    /// At pill size, slightly bigger eyes so they stay bright, not a smudge.
    var small: Bool

    var animatableData: CGFloat {
        get { eyeOpen }
        set { eyeOpen = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var ears = Path()
        ears.move(to: point(0.12, 0.52))
        ears.addLine(to: point(0.17, 0.04))
        ears.addLine(to: point(0.46, 0.34))
        ears.closeSubpath()
        ears.move(to: point(0.88, 0.52))
        ears.addLine(to: point(0.83, 0.04))
        ears.addLine(to: point(0.54, 0.34))
        ears.closeSubpath()

        let head = Path(ellipseIn: CGRect(
            x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.29,
            width: rect.width * 0.80, height: rect.height * 0.66
        ))

        let eyeW = rect.width * (small ? 0.15 : 0.11)
        let eyeH = max(rect.height * (small ? 0.23 : 0.18) * eyeOpen, 0.6)
        var eyes = Path()
        for x in [0.35, 0.65] {
            let center = point(x, 0.60)
            eyes.addRoundedRect(
                in: CGRect(x: center.x - eyeW / 2, y: center.y - eyeH / 2, width: eyeW, height: eyeH),
                cornerSize: CGSize(width: eyeW / 2, height: min(eyeW, eyeH) / 2)
            )
        }
        return ears.union(head).subtracting(eyes)
    }
}
