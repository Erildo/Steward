import SwiftUI
import StewardCore

struct FeedView: View {
    @State private var model = FeedModel.launch()
    @State private var showsTaste = false
    @State private var showsSaved = false
    @State private var lastHidden: FeedCard?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        NavigationStack {
            content
                .background(Palette.ground)
                .navigationTitle("Feed")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Saved", systemImage: "bookmark") { showsSaved = true }
                        Button("Your taste", systemImage: "slider.horizontal.3") { showsTaste = true }
                    }
                }
                .tint(Palette.ink)
                // The first batch waits for the owner to finish telling Steward
                // what they like, then starts as the sheet closes.
                .sheet(isPresented: $showsTaste, onDismiss: { Task { await model.appear() } }) {
                    TasteView().environment(model)
                }
                .sheet(isPresented: $showsSaved) {
                    SavedView().environment(model)
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
                    if let batch = model.batch {
                        ForEach(FeedCard.Section.allCases, id: \.self) { section in
                            let cards = model.cards(in: section)
                            if !cards.isEmpty {
                                SectionHeader(section: section)
                                ForEach(cards) { card in
                                    // Each section opens on its lead find, pictured large.
                                    FeedCardView(card: card, isLead: card.id == cards.first?.id) { hide(card) }
                                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                                }
                            }
                        }
                        FeedEnd(batch: batch) { showsSaved = true }
                    } else if model.status != .loading, model.status != .noModel {
                        Text("Pull down to get today's finds.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
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
                   text: "Steward can't search for new things yet. What you tell it now is kept for when it can.",
                   action: ("Edit Your Taste", { showsTaste = true }))
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
                .tint(Palette.orangeText)
                .frame(minHeight: 44)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: card.id) {
                // VoiceOver users reach Undo by swiping, which takes longer
                // than a glance, so the toast waits for the next hide instead.
                guard !voiceOver else { return }
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.snappy) { lastHidden = nil }
            }
        }
    }

    private func hide(_ card: FeedCard) {
        withAnimation(.snappy) {
            model.react(.less, to: card)
            lastHidden = card
        }
        AccessibilityNotification.Announcement("Hidden. Undo is at the bottom of the screen.").post()
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
            if let subtitle = section.subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Where today's finds stop: how many there were, when the next ones come,
/// and the way to what the owner kept.
private struct FeedEnd: View {
    let batch: FeedBatch
    let openSaved: () -> Void

    @Environment(FeedModel.self) private var model

    var body: some View {
        let count = batch.visibleCards.count
        let today = Calendar.current.isDateInToday(batch.createdAt)
        VStack(spacing: 4) {
            Text(today ? "That's all for today." : "That's everything from \(batch.createdAt.formatted(.dateTime.weekday(.wide))).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text("\(count) \(count == 1 ? "find" : "finds"). Steward looks again tomorrow, or pull down for more now.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            if !model.taste.saved.isEmpty {
                Button("Saved Finds (\(model.taste.saved.count))", systemImage: "bookmark.fill", action: openSaved)
                    .font(.subheadline.weight(.semibold))
                    .tint(Palette.orangeText)
                    .frame(minHeight: 44)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}

private struct Banner: View {
    let systemImage: String
    let text: String
    var action: (title: String, run: () -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(Palette.muted)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.subheadline).foregroundStyle(Palette.ink)
                if let action {
                    Button(action.title, action: action.run)
                        .font(.subheadline.weight(.semibold))
                        .tint(Palette.ink)
                        .frame(minHeight: 44)
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, action == nil ? 0 : -12)
            Spacer(minLength: 0)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, dismiss == nil ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.stewardBubble, in: .rect(cornerRadius: Palette.cardRadius))
    }
}

struct FeedCardView: View {
    let card: FeedCard
    var isLead = false
    let hide: () -> Void

    @Environment(FeedModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    var body: some View {
        let opened = model.isOpened(card)
        VStack(alignment: .leading, spacing: 0) {
            // The page's own picture, when it has one.
            if isLead { LeadImageView(url: card.url, style: .banner) }

            VStack(alignment: .leading, spacing: 10) {
                // Steward's reason leads, the way a friend says why before what.
                if !card.why.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        StewardAvatar(size: 20, blinks: false)
                        Text(card.why)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.ink)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Why: \(card.why)")
                }

                Button(action: open) {
                    HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title)
                            .font(.headline)
                            .foregroundStyle(opened ? Palette.muted : Palette.ink)
                        if !card.summary.isEmpty {
                            Text(card.summary)
                                .font(.subheadline)
                                .foregroundStyle(Palette.muted)
                        }
                        // One Text, so it wraps like a sentence at large sizes.
                        Text("\(Text(card.source).fontWeight(.semibold)) · \(card.topic)\(opened ? " · Opened" : "")")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !isLead { LeadImageView(url: card.url, style: .thumbnail) }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
                .accessibilityHint("Opens in Safari")

                if let lens = card.lens {
                    FeedLensView(lens: lens)
                        .padding(.top, 4)
                    if let follow = FollowUp(card: card) {
                        Button {
                            router.askSteward(follow.request)
                        } label: {
                            HStack(spacing: 8) {
                                StewardAvatar(size: 22, blinks: false)
                                Text(follow.title)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .tint(Palette.orangeText)
                        .frame(minHeight: 44)
                        .padding(.vertical, -6)
                        .accessibilityHint("Opens a chat with Steward, written but not sent")
                    }
                }

                // One row when every label fits unwrapped; at larger text sizes the
                // save/share pair drops below, then each reaction gets its own line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) {
                        reactions
                        Spacer(minLength: 0)
                        keepers
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) { reactions }
                        keepers
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        reactions
                        keepers
                    }
                }
                .padding(.trailing, -10)
                .padding(.vertical, -8)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.stewardBubble)
        .clipShape(.rect(cornerRadius: Palette.cardRadius))
        .contentShape(.contextMenuPreview, .rect(cornerRadius: Palette.cardRadius))
        .contextMenu { menu }
    }

    private func open() {
        model.markOpened(card)
        openURL(card.url)
    }

    @ViewBuilder
    private var reactions: some View {
        let liked = model.reaction(to: card) == .more
        QuietButton(title: "More like this", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup", selected: liked) {
            model.react(.more, to: card)
        }
        QuietButton(title: "Not for me", systemImage: "hand.thumbsdown", selected: false, action: hide)
    }

    /// Save and Share: 44 pt targets whose glyphs sit close together.
    private var keepers: some View {
        HStack(spacing: 0) {
            let saved = model.isSaved(card)
            Button(saved ? "Saved" : "Save", systemImage: saved ? "bookmark.fill" : "bookmark") {
                model.toggleSaved(card)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(saved ? Palette.orangeText : Palette.muted)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            ShareLink(item: card.url) {
                Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .foregroundStyle(Palette.muted)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open", systemImage: "safari", action: open)
        let liked = model.reaction(to: card) == .more
        Button(liked ? "Undo More Like This" : "More Like This", systemImage: "hand.thumbsup") {
            model.react(.more, to: card)
        }
        Button("Not for Me", systemImage: "hand.thumbsdown", action: hide)
        Button("Ask Steward", systemImage: "bubble.left") {
            router.askSteward(FollowUp(card: card)?.request ?? "Tell me more about \"\(card.title)\": \(card.url.absoluteString)")
        }
        let saved = model.isSaved(card)
        Button(saved ? "Remove from Saved" : "Save", systemImage: saved ? "bookmark.slash" : "bookmark") {
            model.toggleSaved(card)
        }
        ShareLink(item: card.url)
    }
}

/// What Steward can do next with a find whose lens invites it: start the
/// plan, keep the date, or help choose. Handed to Chat written, not sent.
private struct FollowUp {
    let title: String
    let request: String

    init?(card: FeedCard) {
        let link = card.url.absoluteString
        switch card.lens {
        case .plan:
            title = "Start This With Steward"
            request = "Help me start this plan and keep me on track: \"\(card.title)\" (\(link))"
        case .date(let spot):
            guard let date = spot.date, date > .now else { return nil }
            title = "Remind Me"
            request = "Remind me before \(date.formatted(.dateTime.weekday(.wide).day().month(.wide))): \(spot.title), for \"\(card.title)\" (\(link))"
        case .compare(let compare):
            title = "Help Me Choose"
            request = "Help me choose between \(compare.options.map(\.name).joined(separator: ", ")) for \"\(card.title)\" (\(link))"
        default:
            return nil
        }
    }
}

/// A reaction with no fill of its own: it stays below the find in weight and
/// turns orange only once chosen.
private struct QuietButton: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? Palette.orangeText : Palette.muted)
                .padding(.trailing, 16)
                .frame(minHeight: 44)
                .contentShape(.rect)
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

    /// Only where the title alone doesn't say it.
    var subtitle: String? {
        switch self {
        case .forYou, .worthALook: nil
        case .towardGoals: "A step forward on what you're working on"
        }
    }
}
