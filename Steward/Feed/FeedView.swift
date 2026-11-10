import SwiftUI
import StewardCore

struct FeedView: View {
    @State private var model = FeedModel.launch()
    @State private var showsTaste = false
    @State private var lastHidden: FeedCard?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .background(Palette.ground)
                .navigationTitle("Feed")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Your taste", systemImage: "slider.horizontal.3") { showsTaste = true }
                    }
                }
                .sheet(isPresented: $showsTaste) {
                    TasteView().environment(model)
                }
                .overlay(alignment: .bottom) { undoToast }
        }
        .environment(model)
        .task { await model.appear() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.appear() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.taste.isEmpty {
            FirstRun { showsTaste = true }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    banners
                    if model.batch == nil {
                        if model.status != .loading, model.status != .noModel {
                            Text("Pull down to get today's finds.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    } else {
                        ForEach(FeedCard.Section.allCases, id: \.self) { section in
                            let cards = model.cards(in: section)
                            if !cards.isEmpty {
                                SectionHeader(section: section)
                                ForEach(cards) { card in
                                    FeedCardView(card: card) { hide(card) }
                                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(.snappy, value: model.batch)
            }
            .refreshable { await model.refresh() }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !model.justShared.isEmpty {
            Banner(
                systemImage: "square.and.arrow.down",
                text: model.justShared.count == 1
                    ? "Got \"\(model.justShared[0].title)\". It shapes your next finds."
                    : "Got \(model.justShared.count) things you shared. They shape your next finds.",
                dismiss: { model.dismissJustShared() }
            )
        }
        switch model.status {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for today's finds…").font(.subheadline).foregroundStyle(Palette.muted)
            }
            .padding(.vertical, 6)
        case .noModel:
            Banner(systemImage: "bolt.horizontal.circle",
                   text: "Steward isn't connected to a model yet, so it can't look for new things.")
        case .failed(let message):
            Banner(systemImage: "exclamationmark.circle", text: message)
        case .idle:
            if let batch = model.batch {
                Text(batch.createdAt, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if let card = lastHidden {
            HStack(spacing: 12) {
                Text("Hidden. You'll see less like this.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Button("Undo") {
                    withAnimation(.snappy) { model.undoHide(card) }
                    lastHidden = nil
                }
                .font(.subheadline.weight(.semibold))
                .tint(Palette.orange)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: card.id) {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.snappy) { lastHidden = nil }
            }
        }
    }

    private func hide(_ card: FeedCard) {
        withAnimation(.snappy) {
            model.react(.less, to: card)
            lastHidden = card
        }
    }
}

// MARK: Pieces

private struct FirstRun: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            StewardAvatar(size: 64)
            VStack(spacing: 8) {
                Text("Tell Steward what you love")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text("It can't see what you watch or read. Tell it a few things, or share links to it from any app, and each day it finds what's worth your time.")
                    .font(.body)
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            }
            Button(action: start) {
                Text("Get Started").font(.headline).padding(.horizontal, 12).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.orange)
            .foregroundStyle(Palette.onOrange)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SectionHeader: View {
    let section: FeedCard.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
            Text(section.subtitle).font(.footnote).foregroundStyle(Palette.muted)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct Banner: View {
    let systemImage: String
    let text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(Palette.muted)
            Text(text).font(.subheadline).foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.stewardBubble, in: .rect(cornerRadius: Palette.cardRadius))
    }
}

struct FeedCardView: View {
    let card: FeedCard
    let hide: () -> Void

    @Environment(FeedModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Link(destination: card.url) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(card.source).fontWeight(.semibold)
                        Text("·")
                        Text(card.topic).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.muted)

                    Text(card.title)
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)

                    if !card.summary.isEmpty {
                        Text(card.summary)
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .accessibilityHint("Opens in Safari")

            if !card.why.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    StewardAvatar(size: 20, blinks: false)
                    Text(card.why)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Why: \(card.why)")
            }

            HStack(spacing: 8) {
                let liked = model.reaction(to: card) == .more
                PillButton(title: "More like this", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup", selected: liked) {
                    model.react(.more, to: card)
                }
                PillButton(title: "Not for me", systemImage: "hand.thumbsdown", selected: false, action: hide)
                Spacer(minLength: 0)
                let saved = model.isSaved(card)
                Button(saved ? "Saved" : "Save", systemImage: saved ? "bookmark.fill" : "bookmark") {
                    model.toggleSaved(card)
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(saved ? Palette.orange : Palette.muted)
                .frame(width: 36, height: 36)
                .contentShape(.rect)
                ShareLink(item: card.url) {
                    Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                }
                .foregroundStyle(Palette.muted)
                .frame(width: 36, height: 36)
            }
            .font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.stewardBubble, in: .rect(cornerRadius: Palette.cardRadius))
    }
}

private struct PillButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Palette.orange : Palette.ink)
                .background(Palette.ground, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension FeedCard.Section {
    var title: String {
        switch self {
        case .forYou: "For you"
        case .worthALook: "Worth a look"
        case .towardGoals: "Toward your goals"
        }
    }

    var subtitle: String {
        switch self {
        case .forYou: "More of what you love"
        case .worthALook: "Next to your interests"
        case .towardGoals: "A step forward on what you're working on"
        }
    }
}
