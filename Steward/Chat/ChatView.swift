import SwiftUI

struct ChatView: View {
    @State private var model = ChatModel.launch()
    @State private var draft = ""
    @State private var showsNewConversationConfirm = false
    @State private var showsPanel = false
    @State private var reviewRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Appearance.storageKey, store: Appearance.store) private var appearance = Appearance.light
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack {
            thread
                .background(Palette.ground)
                .safeAreaInset(edge: .bottom) {
                    Composer(text: $draft) {
                        model.send(draft)
                        draft = ""
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .onChange(of: model.activity, initial: true) {
                    LiveErrandActivity.sync(model.activity, errandTitle: model.activeErrand?.title)
                }
                .onChange(of: router.chatDraft, initial: true) {
                    // A task handed over from Tasks: written, but not sent until the owner says so.
                    guard let handed = router.chatDraft else { return }
                    if !handed.isEmpty { draft = handed }
                    router.chatDraft = nil
                }
                .onChange(of: model.activeErrandID) {
                    if model.activeErrandID == nil { showsPanel = false }
                }
                .confirmationDialog("Start a new conversation?", isPresented: $showsNewConversationConfirm, titleVisibility: .visible) {
                    Button("New Conversation", role: .destructive) { model.startNewConversation() }
                } message: {
                    Text("This clears the current thread.")
                }
        }
        .environment(model)
    }

    /// The errand at a glance, in a system popover: it closes on a tap outside
    /// or VoiceOver's escape, takes focus when it opens, and fades under
    /// Reduce Motion.
    @ViewBuilder
    private var panel: some View {
        if let errand = model.activeErrand {
            ErrandPanel(
                errand: errand,
                review: {
                    showsPanel = false
                    reviewRequest += 1
                },
                stop: { model.stopActiveErrand() }
            )
            .frame(width: 320)
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var thread: some View {
        if model.messages.isEmpty {
            EmptyThread()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.showsSampleLabel {
                            Text("Sample conversation")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                                .padding(.top, 4)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                            if let time = ThreadTime.label(for: index, in: model.messages) {
                                time
                                    .font(.caption)
                                    .foregroundStyle(Palette.muted)
                                    .padding(.top, 14)
                                    .padding(.bottom, 8)
                            }
                            MessageRow(
                                message: message,
                                endsGroup: ThreadTime.endsGroup(index, in: model.messages),
                                showsStatus: message.id == latestOwnerMessageID,
                                hasFocusRing: message.id == latestStewardMessageID,
                                retry: { model.retry(message.id) }
                            )
                            .id(message.id)
                        }
                        if model.isStewardWorking {
                            WorkingRow().id("working")
                        }
                    }
                    .backgroundPreferenceValue(FocusRingAnchor.self) { anchor in
                        FocusRing(anchor: anchor, messageID: latestStewardMessageID, reduceMotion: reduceMotion)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { scrollToEnd(proxy) }
                .onChange(of: model.isStewardWorking) { scrollToEnd(proxy) }
                .onChange(of: reviewRequest) {
                    guard let id = model.pendingApprovalMessageID else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var latestOwnerMessageID: UUID? {
        model.messages.last { $0.author == .owner }?.id
    }

    private var latestStewardMessageID: UUID? {
        model.messages.last { $0.author == .steward }?.id
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if model.isStewardWorking {
                proxy.scrollTo("working", anchor: .bottom)
            } else if let last = model.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("New Conversation", systemImage: "square.and.pencil") {
                    showsNewConversationConfirm = true
                }
                .disabled(model.messages.isEmpty)
                Button("Run Demo Errand", systemImage: "play") {
                    model.runDemoFromMenu()
                }
                .disabled(model.activeErrandID != nil)
                Picker("Appearance", systemImage: "circle.lefthalf.filled", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Palette.ink)
                    .accessibilityLabel("Menu")
            }
            // Orange is kept for your words, the tab, send and the focus ring.
            .tint(Palette.ink)
        }
        ToolbarItem(placement: .principal) {
            StewardActivityPill(activity: model.activity) {
                showsPanel.toggle()
            }
            .popover(isPresented: $showsPanel, arrowEdge: .top) { panel }
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// The curled corner on the last bubble of a group. Drawn for the trailing side.
private struct BubbleTail: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: h),
                          control: CGPoint(x: w * 0.25, y: h * 0.8))
        path.addQuadCurve(to: CGPoint(x: -w * 0.7, y: h * 0.82),
                          control: CGPoint(x: w * 0.1, y: h * 1.08))
        path.closeSubpath()
        return path
    }
}

/// Where Steward's latest reply sits, so the thread can draw one ring around it.
nonisolated private struct FocusRingAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The signature move: a thin orange ring on Steward's newest reply. It is one
/// ring, so when a new reply lands it travels down to it; under Reduce Motion
/// it fades out of the old reply and into the new one instead. It sits behind
/// the bubbles, so the tail reads as passing through it.
private struct FocusRing: View {
    let anchor: Anchor<CGRect>?
    let messageID: UUID?
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            if let anchor {
                let rect = proxy[anchor].insetBy(dx: -3.5, dy: -3.5)
                if reduceMotion {
                    ring(in: rect)
                        .id(messageID)
                        .transition(.opacity)
                } else {
                    ring(in: rect)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.45), value: messageID)
        .accessibilityHidden(true)
    }

    private func ring(in rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: Palette.bubbleRadius + 3.5)
            .strokeBorder(Palette.orange, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let endsGroup: Bool
    let showsStatus: Bool
    var hasFocusRing = false
    let retry: () -> Void

    private var isOwner: Bool { message.author == .owner }
    private var fill: Color { isOwner ? Palette.orange : Palette.stewardBubble }

    var body: some View {
        VStack(alignment: isOwner ? .trailing : .leading, spacing: 3) {
            HStack {
                if isOwner { Spacer(minLength: 56) }
                bubble
                if !isOwner { Spacer(minLength: 56) }
            }
            if let attachment = message.attachment {
                MessageAttachmentView(attachment: attachment)
                    .padding(.top, 5)
                    .padding(.trailing, 20)
            }
            if showsStatus {
                status
            }
        }
        .padding(.bottom, endsGroup ? 10 : 3)
    }

    private var bubble: some View {
        Text(message.text)
            .font(.body)
            .foregroundStyle(isOwner ? Palette.onOrange : Palette.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(fill, in: .rect(cornerRadius: Palette.bubbleRadius))
            .anchorPreference(key: FocusRingAnchor.self, value: .bounds) { hasFocusRing ? $0 : nil }
            .background(alignment: isOwner ? .bottomTrailing : .bottomLeading) {
                if endsGroup && message.attachment == nil {
                    BubbleTail()
                        .fill(fill)
                        .frame(width: 9, height: 15)
                        .scaleEffect(x: isOwner ? 1 : -1)
                        .offset(x: isOwner ? 4 : -4)
                }
            }
            .accessibilityLabel("\(isOwner ? "You" : "Steward"): \(message.text)")
    }

    @ViewBuilder
    private var status: some View {
        switch message.status {
        case .sending:
            statusText("Sending…")
        case .delivered:
            statusText("Delivered")
        case .failed:
            Button(action: retry) {
                Label("Not Delivered. Tap to retry", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(.systemRed))
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Palette.muted)
            .padding(.trailing, 2)
    }
}

private struct WorkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Palette.muted)
            Text("Steward is working")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

private struct EmptyThread: View {
    var body: some View {
        VStack(spacing: 10) {
            StewardAvatar(size: 56)
                .padding(.bottom, 4)
            Text("What needs sorting?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text("Tell Steward the errand in your own words. Nothing is sent or paid until you say yes.")
                .font(.body)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Composer: View {
    @Binding var text: String
    let send: () -> Void

    @State private var showsVoiceNotice = false
    /// The send circle grows with the reader's text size, like the glyphs do.
    @ScaledMetric(relativeTo: .body) private var sendSize: CGFloat = 34
    /// Tap area for the composer's buttons: 44 pt at default sizes, growing
    /// with the glyphs at large ones so they keep a margin inside the capsule.
    @ScaledMetric(relativeTo: .body) private var scaledControl: CGFloat = 44
    private var control: CGFloat { min(max(scaledControl, 44), 64) }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Menu {
                Section("Attachments aren't connected yet") {
                    Button("Photo", systemImage: "photo") {}.disabled(true)
                    Button("File", systemImage: "doc") {}.disabled(true)
                }
            } label: {
                icon("plus").accessibilityLabel("Add attachment")
            }

            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .foregroundStyle(Palette.ink)
                .tint(Palette.orange)
                .padding(.vertical, 11)

            if canSend {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Palette.onOrange)
                        .frame(width: sendSize, height: sendSize)
                        .background(Palette.orange, in: .circle)
                        .frame(minWidth: control, minHeight: control)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Send")
            } else {
                Button { showsVoiceNotice = true } label: {
                    icon("mic").accessibilityLabel("Voice")
                }
            }
        }
        .padding(.horizontal, 2)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .alert("Voice isn't connected yet", isPresented: $showsVoiceNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("For now, type your message or use the keyboard's dictation key.")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body.weight(.medium))
            .foregroundStyle(Palette.ink)
            .frame(minWidth: control, minHeight: control)
            .contentShape(.rect)
    }
}

enum ThreadTime {
    private static func startsNewBlock(_ index: Int, in messages: [ChatMessage]) -> Bool {
        index == 0 || messages[index].date.timeIntervalSince(messages[index - 1].date) >= 3600
    }

    /// A time opens the thread and any gap of an hour or more.
    static func label(for index: Int, in messages: [ChatMessage]) -> Text? {
        guard startsNewBlock(index, in: messages) else { return nil }
        let date = messages[index].date
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) {
            day = "Today"
        } else if calendar.isDateInYesterday(date) {
            day = "Yesterday"
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        }
        return Text("\(Text(day).fontWeight(.semibold)) \(time)")
    }

    /// The last bubble before the author changes or a new time block starts gets the tail.
    static func endsGroup(_ index: Int, in messages: [ChatMessage]) -> Bool {
        let next = index + 1
        guard next < messages.count else { return true }
        return messages[next].author != messages[index].author || startsNewBlock(next, in: messages)
    }
}
