import SwiftUI

/// What Steward noticed about the owner's life this week: goals, changes and
/// how they tend to work, each with its proof and a next step, then what
/// Steward has finished for them.
struct InsightsView: View {
    @Environment(InsightsModel.self) private var model
    @State private var showsKnown = false

    var body: some View {
        NavigationStack {
            content
                .background(Palette.ground)
                .navigationTitle("Insights")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("What Steward Knows", systemImage: "person.text.rectangle") { showsKnown = true }
                    }
                }
                .tint(Palette.ink)
                .sheet(isPresented: $showsKnown) {
                    KnownView().environment(model)
                }
                .overlay(alignment: .bottom) { StopUndoToast() }
        }
        .environment(model)
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            FirstRun { showsKnown = true }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    weekLine
                    if let lead = model.lead, !model.isHidden(lead) {
                        InsightTicket(insight: lead, isLead: true)
                    }
                    section("Your goals", "What you told Steward you're working toward", .goal)
                    section("Changes", "What's different lately", .change)
                    section("About you", "How you tend to work", .aboutYou)
                    if !model.wins.isEmpty {
                        SectionHeader(title: "Wins", subtitle: "What Steward finished for you")
                        WinsTicket()
                    }
                    end
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(.snappy, value: model.hiddenCount)
            }
        }
    }

    private var weekLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Week of \(model.weekOf.formatted(.dateTime.day().month(.wide)))")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.muted)
            if let read = model.readSummary {
                Text(read).font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section(_ title: String, _ subtitle: String, _ kind: Insight.Kind) -> some View {
        let items = model.insights(kind)
        if !items.isEmpty {
            SectionHeader(title: title, subtitle: subtitle)
            ForEach(items) { insight in
                InsightTicket(insight: insight)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var end: some View {
        VStack(spacing: 4) {
            Text("That's this week.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text("Steward looks again on Sunday. Everything it used is in What Steward Knows.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            Button("What Steward Knows", systemImage: "person.text.rectangle") { showsKnown = true }
                .font(.subheadline.weight(.semibold))
                .tint(Palette.orangeText)
                .frame(minHeight: 44)
            if model.isSample {
                Text("Sample insights: nothing here is real.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

// MARK: A finding

/// One finding on a ticket: what Steward noticed, the picture that proves
/// it, why it thinks so, and what to do about it.
private struct InsightTicket: View {
    let insight: Insight
    var isLead = false

    @Environment(InsightsModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var showsWhy = false
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Ticket(kind: isLead ? "This week" : insight.kind.label,
               status: insight.status,
               needsYou: insight.statusNeedsYou) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(insight.title)
                        .font(isLead ? .title2.weight(.semibold) : .title3.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(insight.detail)
                        .font(isLead ? .body : .subheadline)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if let chart = insight.chart {
                    ChartBlockView(chart: chart, drawn: drawn)
                        .padding(.top, 4)
                }
                why
            }
        } actions: {
            actions
        }
        // The one authored moment: each chart draws in the first time it is
        // seen, then stays drawn. Reduce Motion shows it at once.
        .onAppear {
            guard !drawn else { return }
            if model.hasDrawn(insight) || reduceMotion {
                drawn = true
            } else {
                withAnimation(.easeOut(duration: 0.7).delay(0.15)) { drawn = true }
            }
            model.markDrawn(insight)
        }
    }

    /// How sure Steward is and what it rests on; the evidence opens in place.
    private var why: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { showsWhy.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("\(insight.confidence.label), from \(insight.basis)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.muted)
                        .rotationEffect(.degrees(showsWhy ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Why Steward thinks this: \(insight.confidence.label), from \(insight.basis)")
            .accessibilityValue(showsWhy ? "Shown" : "Hidden")

            if showsWhy {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(insight.evidence, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: item.source.systemImage)
                                .font(.footnote)
                                .foregroundStyle(Palette.muted)
                                .frame(width: 18)
                            Text(item.text)
                                .font(.footnote)
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, -6)
                .transition(.opacity)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let step = insight.nextStep {
                Button { router.askSteward(step.request) } label: {
                    Label(step.label, systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.orangeText)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .overlay { Capsule().strokeBorder(Palette.orange, lineWidth: 1.5) }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Chat with this written for you to send")
            }
            HStack(spacing: 8) {
                ReactionButton(title: "That's me", systemImage: "checkmark",
                               selected: model.reaction(to: insight) == .confirmed) {
                    model.react(.confirmed, to: insight)
                }
                ReactionButton(title: "Not quite", systemImage: "xmark",
                               selected: model.reaction(to: insight) == .corrected) {
                    model.react(.corrected, to: insight)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Stop Noticing This", systemImage: "eye.slash", role: .destructive) {
                        withAnimation(.snappy) { model.stopNoticing(insight) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("More")
            }
            if let reaction = model.reaction(to: insight) {
                Text(reaction == .confirmed
                     ? "Kept. Steward will build on this."
                     : "Steward will look again. Say what's off in Chat if you like.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: model.reaction(to: insight))
        .sensoryFeedback(.selection, trigger: model.reaction(to: insight))
    }
}

/// "That's me" and "Not quite": the owner's verdict, one tap, undone by
/// tapping again.
private struct ReactionButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Palette.ground : Palette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(selected ? Palette.ink : Palette.stewardBubble, in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Wins

/// A receipt of what Steward finished: each line with who confirmed it, and
/// the money back at the foot.
private struct WinsTicket: View {
    @Environment(InsightsModel.self) private var model

    var body: some View {
        Ticket(kind: "Wins", status: model.winsSince.map { "Since \($0.formatted(.dateTime.day().month(.abbreviated)))" }) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.wins) { win in
                    row(win)
                    Divider().overlay(Palette.ticketEdge)
                }
                totals
                    .padding(.top, 12)
                Text("When you confirm a win yourself, it counts for more than the company's word.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
    }

    private func row(_ win: Win) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(win.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: win.proof.systemImage)
                    Text("\(win.proof.label), \(win.date.formatted(.dateTime.day().month(.abbreviated)))")
                }
                .font(.caption)
                .foregroundStyle(win.proof == .owner ? Palette.ink : Palette.muted)
            }
            Spacer(minLength: 8)
            if let amount = win.amount {
                Text(money(amount))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
            } else if let monthly = win.monthly {
                Text("\(money(monthly))/mo")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var totals: some View {
        VStack(spacing: 6) {
            if model.totalBack > 0 {
                line("Back to you", money(model.totalBack))
            }
            if model.totalMonthly > 0 {
                line("No longer paying", "\(money(model.totalMonthly)) a month")
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline.weight(.semibold))
            Spacer()
            Text(value).font(.headline.monospacedDigit())
        }
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .combine)
    }

    private func money(_ value: Decimal) -> String {
        value.formatted(.currency(code: "EUR").precision(.fractionLength(value == value.rounded() ? 0 : 2)))
    }
}

private extension Decimal {
    func rounded() -> Decimal {
        var source = self
        var result = Decimal()
        NSDecimalRound(&result, &source, 0, .plain)
        return result
    }
}

// MARK: Pieces

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
            Text(subtitle).font(.footnote).foregroundStyle(Palette.muted)
        }
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct FirstRun: View {
    let openKnown: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            StewardAvatar(size: 64)
            VStack(spacing: 8) {
                Text("Steward is getting to know you")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text("After a week of chats and tasks, it starts to notice things: how your goals are going, what's changing, and how you tend to work. Each one shows its evidence, and you decide what it keeps.")
                    .font(.body)
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            }
            Button(action: openKnown) {
                Text("What Steward Knows").font(.headline).padding(.horizontal, 12).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.orange)
            .foregroundStyle(Palette.onOrange)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// After "Stop Noticing This": a way back, for a few seconds.
private struct StopUndoToast: View {
    @Environment(InsightsModel.self) private var model

    var body: some View {
        if let insight = model.lastHidden {
            HStack(spacing: 16) {
                Text("Steward won't bring this up again.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Button("Undo") { withAnimation(.snappy) { model.undoStop() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.orangeText)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: insight.id) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.snappy) { model.dismissUndo(insight.id) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Undo") { model.undoStop() }
        }
    }
}
