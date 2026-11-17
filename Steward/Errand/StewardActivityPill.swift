import SwiftUI

/// The Steward pill doubles as a live activity: it always says what the agent is doing.
struct StewardActivityPill: View {
    let activity: StewardActivity
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CatLook.nameKey, store: CatLook.store) private var catName = ""

    private var needsYou: Bool { activity == .needsYou }
    /// Only an errand opens the panel; a chat reply has nothing more to show.
    private var opensPanel: Bool {
        switch activity {
        case .working, .needsYou: true
        default: false
        }
    }
    private var name: String {
        let trimmed = catName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Steward" : trimmed
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Quiet hours are checked once a minute, so the cat falls asleep on time.
                TimelineView(.everyMinute) { context in
                    StewardAvatar(mood: mood(at: context.date))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(needsYou ? Palette.onOrange : Palette.ink)
                    .lineLimit(1)
                    .contentTransition(.opacity)
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
        .allowsHitTesting(opensPanel)
        .glassEffect(needsYou ? .regular.tint(Palette.orange) : .regular, in: .capsule)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: activity)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(opensPanel ? "Shows the errand" : "")
        // VoiceOver hears each change as it happens, not only when it lands on the pill.
        .onChange(of: activity) { _, new in
            guard new != .idle else { return }
            AccessibilityNotification.Announcement(accessibilityText).post()
        }
    }

    /// What Steward is doing, said in words. The owner's name for the cat
    /// leads short statuses; an errand step is long enough on its own.
    private var title: String {
        switch activity {
        case .idle: return name
        case .working(let step, _, _): return step
        default:
            return name == "Steward" ? status : "\(name) · \(status)"
        }
    }

    private var status: String {
        switch activity {
        case .idle: ""
        case .working(let step, _, _): step
        case .needsYou: "Needs your OK"
        case .done: "Done"
        case .replying: "Thinking"
        case .problem: "Couldn't reply"
        case .waiting(let words): words
        }
    }

    private var accessibilityText: String {
        switch activity {
        case .idle: return name
        case .working(let step, let number, let total): return "\(name): \(step), step \(number) of \(total)"
        default: return "\(name): \(status)"
        }
    }

    private func mood(at date: Date) -> CatMood {
        switch activity {
        case .idle: ReviewNudges.quietHours()?.contains(date) == true ? .asleep : .idle
        case .working: .working
        case .replying: .thinking
        case .needsYou: .needsYou
        case .done: .done
        case .problem: .problem
        case .waiting: .waiting
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
            StepList(steps: errand.steps.map { .init(title: $0.title, state: $0.state) })
            HStack(spacing: 8) {
                if errand.phase != .finished {
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
    }
}
