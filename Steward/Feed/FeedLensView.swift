import SwiftUI
import StewardCore

/// A find's lens, drawn inside its card with no card of its own: the facts
/// at a glance, a plan on a rail, what's inside, options side by side, or a
/// calendar leaf for the day that matters.
struct FeedLensView: View {
    let lens: FeedLens

    var body: some View {
        switch lens {
        case .facts(let facts): FactsStrip(facts: facts)
        case .plan(let plan): PlanRail(plan: plan)
        case .list(let list): NumberedList(list: list)
        case .compare(let compare): CompareTiles(compare: compare)
        case .date(let spot): DateLeaf(spot: spot)
        }
    }
}

private struct LensTitle: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: Facts

private struct FactsStrip: View {
    let facts: [FeedLens.Fact]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 {
                        Rectangle().fill(Palette.ticketEdge).frame(width: 1).padding(.vertical, 2)
                    }
                    cell(fact)
                        .padding(.leading, index == 0 ? 0 : 12)
                        .padding(.trailing, 12)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in cell(fact) }
            }
        }
    }

    private func cell(_ fact: FeedLens.Fact) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(fact.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
            Text(fact.label)
                .font(.caption)
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fact.label): \(fact.value)")
    }
}

// MARK: Plan

private struct PlanRail: View {
    let plan: FeedLens.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LensTitle(text: plan.title)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        // The rail: a dot per step, joined by a line.
                        VStack(spacing: 0) {
                            Circle()
                                .fill(index == 0 ? Palette.orange : Palette.stewardBubble)
                                .overlay { Circle().strokeBorder(index == 0 ? Palette.orange : Palette.muted, lineWidth: 1.5) }
                                .frame(width: 11, height: 11)
                                .padding(.top, 4)
                            if index < plan.steps.count - 1 {
                                Rectangle().fill(Palette.ticketEdge).frame(width: 1.5)
                            }
                        }
                        .frame(width: 11)
                        VStack(alignment: .leading, spacing: 1) {
                            if let when = step.when {
                                Text(when)
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.muted)
                            }
                            Text(step.title)
                                .font(.subheadline)
                                .foregroundStyle(Palette.ink)
                        }
                        .padding(.bottom, index < plan.steps.count - 1 ? 12 : 0)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

// MARK: List

private struct NumberedList: View {
    let list: FeedLens.ItemList
    @State private var showsAll = false

    private let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LensTitle(text: list.title)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.items.prefix(showsAll ? list.items.count : shown).enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.muted)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(item)
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if list.items.count > shown {
                Button(showsAll ? "Show Fewer" : "Show All \(list.items.count)") {
                    withAnimation(.snappy) { showsAll.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Palette.orangeText)
                .frame(minHeight: 44)
                .padding(.vertical, -8)
            }
        }
    }
}

// MARK: Compare

private struct CompareTiles: View {
    let compare: FeedLens.Compare

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LensTitle(text: compare.title)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) { tiles }
                VStack(alignment: .leading, spacing: 8) { tiles }
            }
        }
    }

    private var tiles: some View {
        ForEach(Array(compare.options.enumerated()), id: \.offset) { _, option in
            VStack(alignment: .leading, spacing: 3) {
                if option.pick {
                    HStack(spacing: 4) {
                        StewardAvatar(size: 14, blinks: false)
                        Text("Steward's pick")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.orangeText)
                }
                Text(option.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                if !option.detail.isEmpty {
                    Text(option.detail)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(minWidth: 88, maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
            .background(option.pick ? Palette.ground : .clear, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.ticketEdge, lineWidth: option.pick ? 0 : 1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: Date

private struct DateLeaf: View {
    let spot: FeedLens.DateSpot

    var body: some View {
        if let date = spot.date {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Text(date, format: .dateTime.month(.abbreviated))
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.onOrange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(Palette.orange)
                    Text(date, format: .dateTime.day())
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 52, height: 56)
                .background(Palette.ground)
                .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(Self.relative(date))
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(spot.title), \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(Self.relative(date))")
        }
    }

    /// "Today", "Tomorrow", "In 12 days", "3 days ago", in whole days.
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...: return "In \(days) days"
        default: return "\(-days) days ago"
        }
    }
}
