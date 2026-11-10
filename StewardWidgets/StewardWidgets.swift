import ActivityKit
import SwiftUI
import WidgetKit

@main
struct StewardWidgets: WidgetBundle {
    var body: some Widget {
        ErrandLiveActivity()
    }
}

private typealias State = ErrandActivityAttributes.ContentState

private extension State {
    var headline: String {
        switch phase {
        case .working: step
        case .needsYou: "Needs your OK"
        case .done: "Done"
        }
    }
}

/// Avatar that changes with the errand, matching the pill in the app.
private struct StatusBadge: View {
    let phase: State.Phase
    var size: CGFloat = 34

    private var symbol: String {
        switch phase {
        case .working: "cat.fill" // unused: the working badge draws StewardAvatar
        case .needsYou: "hand.raised.fill"
        case .done: "checkmark"
        }
    }

    var body: some View {
        if phase == .working {
            StewardAvatar(size: size, blinks: false)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(Palette.onOrange)
                .frame(width: size, height: size)
                .background(Palette.orange, in: .circle)
        }
    }
}

private struct StepBar: View {
    let state: State

    var body: some View {
        ProgressView(value: Double(state.number), total: Double(max(state.total, 1)))
            .tint(Palette.orange)
    }
}

private struct LockScreenView: View {
    let title: String
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatusBadge(phase: state.phase, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.headline).font(.headline).lineLimit(1)
                    Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if state.phase == .working {
                    Text("\(state.number)/\(state.total)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if state.phase != .done { StepBar(state: state) }
        }
        .padding(16)
    }
}

struct ErrandLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ErrandActivityAttributes.self) { context in
            LockScreenView(title: context.attributes.errandTitle, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusBadge(phase: context.state.phase, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .working {
                        Text("\(context.state.number)/\(context.state.total)")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxHeight: .infinity)
                            .padding(.trailing, 6)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.headline).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(context.attributes.errandTitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase != .done {
                        StepBar(state: context.state).padding(.horizontal, 6)
                    }
                }
            } compactLeading: {
                StatusBadge(phase: context.state.phase, size: 22)
                    .padding(.leading, 4)
            } compactTrailing: {
                switch context.state.phase {
                case .working:
                    Text("\(context.state.number)/\(context.state.total)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                case .needsYou:
                    Text("OK?").font(.caption2.weight(.bold)).foregroundStyle(Palette.orange)
                case .done:
                    Text("Done").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                }
            } minimal: {
                StatusBadge(phase: context.state.phase, size: 22)
            }
            .keylineTint(Palette.orange)
        }
    }
}
