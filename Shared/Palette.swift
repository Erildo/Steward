import SwiftUI
import UIKit

/// Steward's colours. White by default, with a dark theme the owner can choose.
enum Palette {
    static let ground = dynamic(light: 0xFFFFFF, dark: 0x0B0D12)
    static let ink = dynamic(light: 0x1C1C1E, dark: 0xF2F0EA)
    static let stewardBubble = dynamic(light: 0xEDEDF0, dark: 0x1C2029)
    /// 5:1 or better on the ground and on Steward's bubbles, in both themes.
    static let muted = dynamic(light: 0x636367, dark: 0xA0A6B4)
    /// Primary: ginger, the cat's coat. Only on your words, the current tab,
    /// send and the focus ring. Near-black text on it is 6.2:1.
    static let orange = dynamic(light: 0xF06E32, dark: 0xF06E32)
    /// Orange for small text and thin strokes. The primary is 3:1 on white,
    /// too faint for words, so light mode deepens it (5.7:1 on white, 4.9:1
    /// on Steward's bubbles).
    static let orangeText = dynamic(light: 0xB04512, dark: 0xF06E32)
    static let onOrange = dynamic(light: 0x1F0D05, dark: 0x1F0D05)
    /// Behind the ginger cat: warm cream, never the black-and-orange of Halloween.
    static let catGround = dynamic(light: 0xF3E8D6, dark: 0x2B2420)
    /// Behind the owner's initials: a step off the grouped rows they sit on.
    static let ownerTint = dynamic(light: 0xD8D8DF, dark: 0x2E3443)
    /// Grouped task rows on the ground.
    static let row = dynamic(light: 0xF2F2F5, dark: 0x161A22)

    static let bubbleRadius: CGFloat = 19
    static let cardRadius: CGFloat = 16

    /// SwiftUI may resolve colours off the main thread (while animating), so
    /// the provider must not be main-actor isolated, or it traps there.
    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { @Sendable traits in
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

    /// Shared with the Share extension through the app group, so the share
    /// sheet follows the owner's choice too. Carries over a choice made before.
    static let store: UserDefaults = {
        let shared = UserDefaults(suiteName: "group.esh.steward") ?? .standard
        if shared.string(forKey: storageKey) == nil,
           let earlier = UserDefaults.standard.string(forKey: storageKey) {
            shared.set(earlier, forKey: storageKey)
        }
        return shared
    }()

    static var current: Appearance {
        store.string(forKey: storageKey).flatMap(Appearance.init(rawValue:)) ?? .light
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
    }

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

/// The owner's cat: its coat and name, chosen in the Steward tab. Kept in
/// the app group, so widgets draw the same cat.
enum CatLook {
    static let coatKey = "cat.coat"
    static let nameKey = "cat.name"
    static var store: UserDefaults { Appearance.store }
}

enum CatCoat: String, CaseIterable, Identifiable {
    case ginger, grey, cream, smoke

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ginger: "Ginger"
        case .grey: "Grey"
        case .cream: "Cream"
        case .smoke: "Smoke"
        }
    }

    /// Every coat keeps the dark eyes readable and stands off the cream (and,
    /// in the dark theme, the brown) disk behind it.
    var fur: Color {
        switch self {
        case .ginger: Palette.orange
        case .grey: Palette.dynamic(light: 0x8C8F99, dark: 0x9A9DA7)
        case .cream: Palette.dynamic(light: 0xDDB67E, dark: 0xE2C28F)
        case .smoke: Palette.dynamic(light: 0x55525A, dark: 0x7A7680)
        }
    }

    /// Dark eyes on the light coats; amber on smoke, where dark ones vanish.
    var eyes: Color {
        self == .smoke ? Palette.dynamic(light: 0xF2B84B, dark: 0xF6C760) : Palette.onOrange
    }
}

/// How the cat looks, from what Steward is really doing. Eyes and ears only,
/// so each one still reads at pill size.
enum CatMood: CaseIterable, Identifiable, Equatable {
    case idle, thinking, working, needsYou, waiting, done, problem, asleep

    var id: Self { self }

    var title: String {
        switch self {
        case .idle: "Calm"
        case .thinking: "Thinking"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .waiting: "Waiting"
        case .done: "Done"
        case .problem: "Stuck"
        case .asleep: "Asleep"
        }
    }

    /// Picked up a message or a step: the ears perk once.
    var isBusy: Bool { self == .thinking || self == .working }

    /// The left ear's turn in degrees; the right one mirrors it.
    fileprivate var earTilt: Double {
        switch self {
        case .working: 6
        case .problem: -32
        case .asleep: -12
        default: 0
        }
    }

    fileprivate func eyes(glance: CGFloat) -> CatEyes.Pose {
        switch self {
        case .thinking: .init(width: 1, height: 1, dx: glance, dy: -0.04)
        case .working: .init(width: 1.05, height: 0.45, dx: 0, dy: 0)
        case .needsYou: .init(width: 1.12, height: 1.12, dx: 0, dy: 0)
        case .waiting: .init(width: 1, height: 0.32, dx: 0, dy: 0)
        case .problem: .init(width: 0.85, height: 0.7, dx: 0, dy: 0.06)
        default: .init()
        }
    }
}

/// Steward's avatar: a cat on cream, ginger unless the owner picked another
/// coat. Independent, unbothered by companies, and on your side. It blinks now
/// and then in the app (widgets pass `blinks: false`), and its `mood` shows
/// what Steward is doing: ears perk when it picks something up, eyes drift
/// while it thinks, it hops once when it's done. Reduce Motion keeps every
/// pose and drops the movement.
struct StewardAvatar: View {
    var size: CGFloat = 30
    var blinks = true
    /// Ink instead of orange, for lists where orange is kept for what needs you.
    var neutral = false
    var mood: CatMood = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CatLook.coatKey, store: CatLook.store) private var coat = CatCoat.ginger
    @State private var eyeOpen: CGFloat = 1
    @State private var earKick: Double = 0
    @State private var hops = 0

    private var small: Bool { size < 40 }
    private var moves: Bool { !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: mood != .thinking || !moves)) { context in
            face(glance: glance(at: context.date))
        }
            .frame(width: size * 0.64, height: size * 0.64)
            .rotationEffect(.degrees(mood == .needsYou && !neutral ? -9 : 0))
            .keyframeAnimator(initialValue: 0.0, trigger: hops) { content, lift in
                content.offset(y: -lift * size)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.1, duration: 0.16)
                    SpringKeyframe(0, duration: 0.42, spring: .bouncy)
                }
            }
            .offset(y: size * 0.02)
            .frame(width: size, height: size)
            .background(neutral ? Palette.ink : Palette.catGround, in: .circle)
            .animation(moves ? .smooth(duration: 0.3) : nil, value: mood)
            .accessibilityHidden(true)
            .onChange(of: mood) { old, new in
                guard moves, !neutral else { return }
                if new.isBusy, !old.isBusy { perk() }
                if new == .done { hops += 1 }
            }
            .task(id: blinks && moves && mood != .done && mood != .asleep ? mood : nil) {
                guard blinks, moves, mood != .done, mood != .asleep else { eyeOpen = 1; return }
                let slow = mood == .waiting
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: slow ? 2.5...4 : 3.5...7)))
                    withAnimation(.easeIn(duration: slow ? 0.3 : 0.07)) { eyeOpen = 0.12 }
                    try? await Task.sleep(for: .milliseconds(slow ? 450 : 120))
                    withAnimation(.easeOut(duration: slow ? 0.35 : 0.1)) { eyeOpen = 1 }
                }
            }
    }

    @ViewBuilder
    private func face(glance: CGFloat) -> some View {
        ZStack {
            if neutral {
                CatShape(eyeOpen: eyeOpen, small: small).fill(Palette.ground)
            } else {
                CatShape(eyeOpen: 1, small: small, cutsEyes: false,
                         leftEar: mood.earTilt + earKick, rightEar: mood.earTilt)
                    .fill(coat.fur)
                if mood == .done || mood == .asleep {
                    CatArcEyes(happy: mood == .done, small: small)
                        .stroke(coat.eyes, style: StrokeStyle(lineWidth: max(size * 0.64 * 0.045, 1.4), lineCap: .round))
                        .transition(.opacity)
                } else {
                    CatEyes(eyeOpen: eyeOpen, small: small, pose: mood.eyes(glance: glance))
                        .fill(coat.eyes)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Eyes drift side to side while Steward thinks; held to one side under Reduce Motion.
    private func glance(at date: Date) -> CGFloat {
        guard mood == .thinking else { return 0 }
        guard moves else { return -0.04 }
        return 0.05 * sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 2.4)
    }

    /// One quick flick of the left ear.
    private func perk() {
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.08)) { earKick = -14 }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { earKick = 0 }
        }
    }
}

/// The cat's head as one shape: ears joined to a round face. The neutral
/// avatar cuts the eyes out so the ink behind shows through; the coloured one
/// paints dark eyes on top. One head shape means no seams, even under Liquid
/// Glass, which treats overlapping layers separately. Each ear turns about
/// its base: flat when stuck, forward when focused.
nonisolated struct CatShape: Shape {
    /// 1 is open, near 0 is a blink.
    var eyeOpen: CGFloat
    /// At pill size, slightly bigger eyes so they stay bright, not a smudge.
    var small: Bool
    var cutsEyes = true
    /// Degrees; positive turns an ear in towards the middle.
    var leftEar: Double = 0
    var rightEar: Double = 0

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<Double, Double>> {
        get { AnimatablePair(eyeOpen, AnimatablePair(leftEar, rightEar)) }
        set { eyeOpen = newValue.first; leftEar = newValue.second.first; rightEar = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        func ear(_ corners: [(CGFloat, CGFloat)], pivot: (CGFloat, CGFloat), degrees: Double) -> Path {
            var path = Path()
            path.addLines(corners.map { point($0.0, $0.1) })
            path.closeSubpath()
            let center = point(pivot.0, pivot.1)
            let turn = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: degrees * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            return path.applying(turn)
        }
        var ears = ear([(0.12, 0.52), (0.17, 0.04), (0.46, 0.34)], pivot: (0.26, 0.44), degrees: leftEar)
        ears.addPath(ear([(0.88, 0.52), (0.83, 0.04), (0.54, 0.34)], pivot: (0.74, 0.44), degrees: -rightEar))

        let head = Path(ellipseIn: CGRect(
            x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.29,
            width: rect.width * 0.80, height: rect.height * 0.66
        ))

        let face = ears.union(head)
        return cutsEyes ? face.subtracting(CatEyes(eyeOpen: eyeOpen, small: small).path(in: rect)) : face
    }
}

nonisolated struct CatEyes: Shape {
    /// Size and place against the resting eye: scales, and offsets in head widths.
    struct Pose: Equatable {
        var width: CGFloat = 1
        var height: CGFloat = 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
    }

    var eyeOpen: CGFloat
    var small: Bool
    var pose = Pose()

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(AnimatablePair(eyeOpen, pose.width), AnimatablePair(pose.height, AnimatablePair(pose.dx, pose.dy))) }
        set {
            eyeOpen = newValue.first.first
            pose.width = newValue.first.second
            pose.height = newValue.second.first
            pose.dx = newValue.second.second.first
            pose.dy = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let eyeW = rect.width * (small ? 0.15 : 0.11) * pose.width
        let eyeH = max(rect.height * (small ? 0.23 : 0.18) * pose.height * eyeOpen, 0.6)
        var eyes = Path()
        for x in [0.35, 0.65] {
            let center = CGPoint(x: rect.minX + rect.width * (x + pose.dx), y: rect.minY + rect.height * (0.60 + pose.dy))
            eyes.addRoundedRect(
                in: CGRect(x: center.x - eyeW / 2, y: center.y - eyeH / 2, width: eyeW, height: eyeH),
                cornerSize: CGSize(width: eyeW / 2, height: min(eyeW, eyeH) / 2)
            )
        }
        return eyes
    }
}

/// Eyes as curves, stroked: happy (^ ^) when done, closed (u u) when asleep.
nonisolated struct CatArcEyes: Shape {
    var happy: Bool
    var small: Bool

    func path(in rect: CGRect) -> Path {
        let half = rect.width * (small ? 0.09 : 0.075)
        let rise = rect.height * (happy ? -0.11 : 0.07)
        var eyes = Path()
        for x in [0.35, 0.65] {
            let center = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * 0.60)
            let edgeY = center.y + (happy ? rect.height * 0.03 : -rect.height * 0.01)
            eyes.move(to: CGPoint(x: center.x - half, y: edgeY))
            eyes.addQuadCurve(to: CGPoint(x: center.x + half, y: edgeY), control: CGPoint(x: center.x, y: edgeY + rise * 2))
        }
        return eyes
    }
}
