import SwiftUI

/// The Steward pill doubles as a live activity: it always says what the agent is doing.
struct StewardActivityPill: View {
    let activity: StewardActivity
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsYou: Bool { activity == .needsYou }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                leading
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(needsYou ? Palette.onOrange : Palette.ink)
                    .lineLimit(1)
                if case .working(_, let number, let total) = activity {
                    Text("\(number)/\(total)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(minHeight: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(activity != .idle && activity != .done)
        .glassEffect(needsYou ? .regular.tint(Palette.orange) : .regular, in: .capsule)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: activity)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(activity == .idle || activity == .done ? "" : "Shows the errand")
    }

    private var title: String {
        switch activity {
        case .idle: "Steward"
        case .working(let step, _, _): step
        case .needsYou: "Needs your OK"
        case .done: "Done"
        }
    }

    private var accessibilityText: String {
        switch activity {
        case .working(let step, let number, let total): "Steward: \(step), step \(number) of \(total)"
        default: "Steward: \(title)"
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .idle:
            StewardAvatar()
        case .working:
            StewardAvatar().overlay { WorkingArc(animates: !reduceMotion) }
        case .needsYou:
            Image(systemName: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.orange)
                .frame(width: 30, height: 30)
                .background(Palette.onOrange, in: .circle)
                .accessibilityHidden(true)
        case .done:
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Palette.onOrange)
                .frame(width: 30, height: 30)
                .background(Palette.orange, in: .circle)
                .accessibilityHidden(true)
        }
    }
}

private struct WorkingArc: View {
    let animates: Bool

    var body: some View {
        TimelineView(.animation(paused: !animates)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .padding(-2)
        }
    }
}

/// Opens from the pill: the whole errand at a glance.
struct ErrandPanel: View {
    let errand: Errand
    let review: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(errand.title).font(.headline).foregroundStyle(Palette.ink)
            StepList(steps: errand.steps)
            HStack(spacing: 8) {
                if errand.approval != .approved {
                    Button("Stop Errand", action: stop)
                        .buttonStyle(.bordered)
                        .tint(Palette.ink)
                }
                if errand.phase == .needsYou {
                    Button("Review", action: review)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.orange)
                        .foregroundStyle(Palette.onOrange)
                }
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thickMaterial, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}
