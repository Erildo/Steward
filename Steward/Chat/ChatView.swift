import SwiftUI
import StewardCore

/// The Chat tab: every conversation with Steward, behind the one you were
/// last in. It opens straight into that conversation; back (or the edge
/// swipe) shows the Chats list, like Messages.
struct ChatTab: View {
    @Environment(AppRouter.self) private var router
    @Environment(ChatModel.self) private var chat
    @Environment(TasksModel.self) private var tasks
    @State private var restored = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.chatPath) {
            ConversationList()
                .navigationDestination(for: ChatRoute.self) { route in
                    switch route {
                    case .new(let token): ConversationView(conversationID: nil).id(token)
                    case .conversation(let id): ConversationView(conversationID: id).id(id)
                    }
                }
        }
        .onAppear(perform: restore)
        .onChange(of: chat.activity, initial: true) {
            LiveErrandActivity.sync(chat.activity, errandTitle: chat.errand?.title)
        }
    }

    /// First time in: the most recent conversation, or a new one.
    private func restore() {
        guard !restored else { return }
        restored = true
        guard router.chatPath.isEmpty else { return }
        if let recent = tasks.stewardTasks.max(by: { $0.lastActivity < $1.lastActivity }) {
            router.chatPath = [.conversation(recent.id)]
        } else {
            router.chatPath = [.new(UUID())]
        }
    }
}

// MARK: Chats

/// Every conversation, pinned first, then the most recent. The face on each
/// row says who moves next, the same as in Tasks.
private struct ConversationList: View {
    @Environment(TasksModel.self) private var tasks
    @Environment(ChatModel.self) private var chat
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var showsProfile = false

    private var shown: [StewardTask] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tasks.conversations }
        return tasks.conversations.filter { task in
            task.goal.localizedStandardContains(query) || task.messages.contains { $0.text.localizedStandardContains(query) }
        }
    }

    var body: some View {
        Group {
            if tasks.conversations.isEmpty {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Tell Steward about an errand, and the conversation stays here.")
                } actions: {
                    Button("Start a Chat") { router.newChat() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.orange)
                        .foregroundStyle(Palette.onOrange)
                }
            } else {
                List {
                    if CaseService.isChatSample {
                        Text("Sample conversations")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Palette.ground)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(shown) { task in
                        NavigationLink(value: ChatRoute.conversation(task.id)) {
                            ConversationRow(task: task)
                        }
                        .listRowBackground(Palette.ground)
                        .swipeActions(edge: .leading) {
                            Button(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin") {
                                tasks.setPinned(task.id, !task.isPinned)
                            }
                            .tint(Palette.orangeText)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(task.id) }
                        }
                        .contextMenu {
                            Button(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin") {
                                tasks.setPinned(task.id, !task.isPinned)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(task.id) }
                        }
                    }
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .listRowBackground(Palette.ground)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: "Search chats")
            }
        }
        .background(Palette.ground)
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showsProfile = true } label: { OwnerAvatar(size: 30) }
                    .accessibilityLabel("You and settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New Chat")
                    .tint(Palette.ink)
            }
        }
        .sheet(isPresented: $showsProfile) { ProfileSheet() }
        .overlay(alignment: .bottom) { UndoToast() }
    }

    private func delete(_ id: UUID) {
        if chat.errandConversationID == id, chat.errand != nil { chat.stopErrand() }
        withAnimation { tasks.deleteStewardTask(id) }
    }
}

private struct ConversationRow: View {
    let task: StewardTask

    @Environment(TasksModel.self) private var tasks

    private var needsYou: Bool { TaskStatus(of: task) == .needsYou }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TaskAvatar(item: .steward(task), size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.goal)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if task.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Palette.muted)
                            .accessibilityLabel("Pinned")
                    }
                    Text(Self.when(task.lastActivity))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(needsYou ? Palette.orangeText : Palette.muted)
                }
                if needsYou {
                    Text(task.statusLine(connected: tasks.canWork))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.orangeText)
                        .lineLimit(2)
                } else {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The last thing said, or what Steward showed when it only showed.
    private var preview: String {
        guard let last = task.messages.last else { return "" }
        let words = last.text.isEmpty ? (last.allBlocks.first.map(Self.describe) ?? "") : ReplyText.plain(last.text)
        return last.author == .owner ? "You: \(words)" : words
    }

    private static func describe(_ block: ReplyBlock) -> String {
        switch block {
        case .choices: "Asked you to pick"
        case .field(let v): "Asked for your \(v.label.lowercased())"
        case .steps(let v): v.title
        case .deadline(let v): v.title
        case .draft: "A draft for your OK"
        case .compare(let v): v.title
        case .timeline(let v): v.title
        case .proof(let v): v.headline
        case .checklist(let v): "\(v.title): \(v.doneCount) of \(v.items.count) done"
        case .chart(let v): v.title ?? "A chart"
        }
    }

    /// Messages' habit: a time today, then the day, then the date.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: One conversation

/// One conversation, or a new one when `conversationID` is nil: the thread,
/// with Steward's pill on top and the composer at the bottom.
struct ConversationView: View {
    let conversationID: UUID?

    @Environment(ChatModel.self) private var chat
    @Environment(TasksModel.self) private var tasks
    @Environment(AppRouter.self) private var router
    /// The conversation a new chat became once the owner sent something.
    @State private var createdID: UUID?
    @State private var draft = ""
    @State private var showsPanel = false
    @State private var caseFile: CaseFile?
    @FocusState private var composing: Bool

    private var id: UUID? { conversationID ?? createdID }
    private var task: StewardTask? { id.flatMap(tasks.stewardTask) }

    var body: some View {
        content
            .background(Palette.ground)
            .safeAreaInset(edge: .bottom) {
                Composer(text: $draft, placeholder: placeholder, focus: $composing, send: send)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .overlay(alignment: .bottom) { UndoToast().padding(.bottom, 64) }
            .sheet(item: $caseFile) { file in
                NavigationStack {
                    CaseDetailView(file: file)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { caseFile = nil } }
                        }
                }
            }
            .onAppear {
                // A task handed over from elsewhere: written, but not sent until the owner says so.
                if conversationID == nil, let handed = router.chatDraft {
                    draft = handed
                    router.chatDraft = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let task {
            ThreadView(task: task, answer: { send($0) })
        } else if id != nil {
            ContentUnavailableView("Chat deleted", systemImage: "trash", description: Text("Undo from the bar below to bring it back."))
        } else {
            NewChatStart { starter in
                if starter.sendsNow {
                    send(starter.text)
                } else {
                    draft = starter.text
                    composing = true
                }
            }
        }
    }

    private var placeholder: String {
        if case .needsAnswer = task?.state { return "Answer Steward" }
        return "Message"
    }

    private func send() {
        send(draft)
        draft = ""
    }

    private func send(_ text: String) {
        let target = chat.send(text, in: id)
        if id == nil { createdID = target }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            StewardActivityPill(activity: chat.activity) { showsPanel.toggle() }
                .popover(isPresented: $showsPanel, arrowEdge: .top) { panel }
        }
        .sharedBackgroundVisibility(.hidden)
        if let task {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(task.isPinned ? "Unpin" : "Pin", systemImage: task.isPinned ? "pin.slash" : "pin") {
                        tasks.setPinned(task.id, !task.isPinned)
                    }
                    if let file = task.caseID.flatMap(tasks.file) {
                        Button("Open Case File", systemImage: "envelope.open") { caseFile = file }
                    }
                    Divider()
                    if chat.errandConversationID == task.id, chat.errand != nil {
                        Button("Stop Errand", systemImage: "stop.circle", role: .destructive) { chat.stopErrand() }
                    } else {
                        StewardTaskMenu(task: task)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(Palette.ink)
                .accessibilityLabel("Chat actions")
            }
        }
    }

    /// The errand at a glance, in a system popover: it closes on a tap outside
    /// or VoiceOver's escape, takes focus when it opens, and fades under
    /// Reduce Motion.
    @ViewBuilder
    private var panel: some View {
        if let errand = chat.errand {
            ErrandPanel(
                errand: errand,
                review: {
                    showsPanel = false
                    if let errandID = chat.errandConversationID, errandID != id {
                        router.openConversation(errandID)
                    }
                    chat.review()
                },
                stop: {
                    showsPanel = false
                    chat.stopErrand()
                }
            )
            .frame(width: 320)
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: The thread

private struct ThreadView: View {
    let task: StewardTask
    let answer: (String) -> Void

    @Environment(ChatModel.self) private var chat
    @Environment(TasksModel.self) private var tasks
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var messages: [StewardTask.Message] { task.messages }
    private var busy: Bool { chat.isWorking(in: task.id) }
    private var latestOwnerID: UUID? { messages.last { $0.author == .owner }?.id }
    private var latestStewardID: UUID? { messages.last { $0.author == .steward }?.id }
    private var isErrandRunningHere: Bool { chat.errandConversationID == task.id && chat.errand != nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if let time = ThreadTime.label(for: index, in: messages) {
                            time
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                                .padding(.top, 14)
                                .padding(.bottom, 8)
                        }
                        MessageRow(
                            message: message,
                            endsGroup: ThreadTime.endsGroup(index, in: messages),
                            showsStatus: message.id == latestOwnerID && message.id == messages.last?.id,
                            hasFocusRing: message.id == latestStewardID,
                            context: BlockContext(
                                conversationID: task.id,
                                messageID: message.id,
                                isLatest: message.id == messages.last?.id && message.author == .steward,
                                isBusy: busy,
                                isRunning: isErrandRunningHere
                            ),
                            answer: answer
                        )
                        .id(message.id)
                    }
                    if busy {
                        WorkingRow().id("working")
                    } else if let problem = tasks.problems[task.id] {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
                .backgroundPreferenceValue(FocusRingAnchor.self) { target in
                    FocusRing(target: target, messageID: latestStewardID, reduceMotion: reduceMotion)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { scrollToEnd(proxy) }
            .task {
                // Long formatted replies and tickets settle their height after the
                // first pass; land on the bottom once they have.
                try? await Task.sleep(for: .milliseconds(80))
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: busy) { scrollToEnd(proxy) }
            .onChange(of: chat.reviewRequest, initial: true) { old, new in
                guard new != old || new > 0, chat.errandConversationID == task.id, let target = chat.approvalMessageID else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            if busy {
                proxy.scrollTo("working", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
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

/// What the focus ring goes around, and how round it is.
private struct RingTarget {
    let anchor: Anchor<CGRect>
    let radius: CGFloat
}

/// Where Steward's latest reply sits, so the thread can draw one ring around it.
nonisolated private struct FocusRingAnchor: PreferenceKey {
    static let defaultValue: RingTarget? = nil
    static func reduce(value: inout RingTarget?, nextValue: () -> RingTarget?) {
        value = value ?? nextValue()
    }
}

/// The signature move: a thin orange ring on Steward's newest reply. It goes
/// round the last ticket when the reply carries one, else round the bubble.
/// It is one ring, so when a new reply lands it travels down to it; under
/// Reduce Motion it fades out of the old reply and into the new one instead.
private struct FocusRing: View {
    let target: RingTarget?
    let messageID: UUID?
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            if let target {
                let rect = proxy[target.anchor].insetBy(dx: -3.5, dy: -3.5)
                if reduceMotion {
                    ring(in: rect, radius: target.radius)
                        .id(messageID)
                        .transition(.opacity)
                } else {
                    ring(in: rect, radius: target.radius)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.45), value: messageID)
        .accessibilityHidden(true)
    }

    private func ring(in rect: CGRect, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius + 3.5)
            .strokeBorder(Palette.orange, lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct MessageRow: View {
    let message: StewardTask.Message
    let endsGroup: Bool
    let showsStatus: Bool
    var hasFocusRing = false
    let context: BlockContext
    let answer: (String) -> Void

    private var isOwner: Bool { message.author == .owner }
    private var fill: Color { isOwner ? Palette.orange : Palette.stewardBubble }
    private var blocks: [ReplyBlock] { message.allBlocks }
    /// Prompts show only while they can still be answered.
    private var promptsLive: Bool { context.isLatest && !context.isBusy }
    private var shown: [(offset: Int, element: ReplyBlock)] {
        Array(blocks.enumerated()).filter { !$0.element.isPrompt || promptsLive }
    }
    /// Steward's replies with structure read as an answer, not a bubble.
    private var isFormatted: Bool { !isOwner && ReplyText.isStructured(message.text) }
    /// The ticket the ring goes round, when this reply has one.
    private var ringedTicket: Int? { hasFocusRing ? blocks.indices.last { !blocks[$0].isPrompt } : nil }

    var body: some View {
        VStack(alignment: isOwner ? .trailing : .leading, spacing: 8) {
            if isFormatted {
                FormattedReply(text: message.text)
                    .anchorPreference(key: FocusRingAnchor.self, value: .bounds) {
                        hasFocusRing && ringedTicket == nil ? RingTarget(anchor: $0, radius: Palette.cardRadius) : nil
                    }
            } else if !message.text.isEmpty {
                HStack {
                    if isOwner { Spacer(minLength: 56) }
                    bubble
                    if !isOwner { Spacer(minLength: 56) }
                }
            }
            ForEach(shown, id: \.offset) { index, block in
                ReplyBlockView(block: block, index: index, context: context, answer: answer)
                    .anchorPreference(key: FocusRingAnchor.self, value: .bounds) {
                        ringedTicket == index ? RingTarget(anchor: $0, radius: Palette.cardRadius) : nil
                    }
                    .padding(.top, block.isPrompt ? 2 : 0)
            }
            if showsStatus {
                Text("Delivered")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.trailing, 2)
                    .padding(.top, -5)
            }
        }
        .padding(.bottom, endsGroup || !blocks.isEmpty ? 12 : 3)
    }

    private var bubble: some View {
        // Steward's bold, italics and links show as such; the owner's words stay as typed.
        Text(isOwner ? AttributedString(message.text) : FormattedReply.inline(message.text))
            .font(.body)
            .foregroundStyle(isOwner ? Palette.onOrange : Palette.ink)
            .textSelection(.enabled)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(fill, in: .rect(cornerRadius: Palette.bubbleRadius))
            .anchorPreference(key: FocusRingAnchor.self, value: .bounds) {
                hasFocusRing && ringedTicket == nil ? RingTarget(anchor: $0, radius: Palette.bubbleRadius) : nil
            }
            .background(alignment: isOwner ? .bottomTrailing : .bottomLeading) {
                if endsGroup && blocks.allSatisfy(\.isPrompt) {
                    BubbleTail()
                        .fill(fill)
                        .frame(width: 9, height: 15)
                        .scaleEffect(x: isOwner ? 1 : -1)
                        .offset(x: isOwner ? 4 : -4)
                }
            }
            .accessibilityLabel("\(isOwner ? "You" : "Steward"): \(isOwner ? message.text : ReplyText.plain(message.text))")
    }
}

/// A reply with structure, laid out as an answer: full width, no bubble,
/// headings, lists and quotes, with its text where a bubble's text would be.
struct FormattedReply: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ReplyText.parse(text).enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index > 0 && isHeading(block) ? 8 : 0)
            }
        }
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Steward: \(ReplyText.plain(text))")
    }

    @ViewBuilder
    private func view(for block: ReplyText.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(Self.inline(text)).font(.body)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Palette.ink).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(Self.inline(item)).font(.body)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(Self.inline(item)).font(.body)
                    }
                }
            }
        case .quote(let text):
            Text(Self.inline(text))
                .font(.subheadline)
                .italic()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.row, in: .rect(cornerRadius: 10))
        }
    }

    private func isHeading(_ block: ReplyText.Block) -> Bool {
        if case .heading = block { true } else { false }
    }

    /// Bold, italics, code and links inside a line; plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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

// MARK: A new chat

/// What a starter does: send at once, or write the start and let the owner finish.
struct Starter: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
    let text: String
    let sendsNow: Bool
}

/// A new chat: the promise, and a few ways in near the thumb.
private struct NewChatStart: View {
    let pick: (Starter) -> Void

    @Environment(TasksModel.self) private var tasks

    private var starters: [Starter] {
        [
            Starter(title: "Cancel my gym membership",
                    detail: tasks.canAct ? "A simulated errand, start to finish" : "Demo errand · nothing is really sent",
                    symbol: "scissors", text: "Cancel my gym membership", sendsNow: true),
            Starter(title: "Chase a refund", detail: "Money a company owes you", symbol: "arrow.uturn.backward.circle", text: "Get my money back from ", sendsNow: false),
            Starter(title: "Dispute a bill", detail: "A charge that looks wrong", symbol: "exclamationmark.bubble", text: "Dispute the bill from ", sendsNow: false),
            Starter(title: "Plan something", detail: "A trip, a move, a weekend", symbol: "map", text: "Plan ", sendsNow: false),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
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
            Spacer(minLength: 24)
            VStack(spacing: 8) {
                ForEach(starters) { starter in
                    Button { pick(starter) } label: { row(starter) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ starter: Starter) -> some View {
        HStack(spacing: 12) {
            Image(systemName: starter.symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(starter.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(starter.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: starter.sendsNow ? "arrow.up.circle.fill" : "chevron.right")
                .font(starter.sendsNow ? .title3 : .footnote.weight(.semibold))
                .foregroundStyle(starter.sendsNow ? Palette.orange : Palette.muted)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(Palette.row, in: .rect(cornerRadius: 14))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(starter.sendsNow ? "Sends this now" : "Writes the start of the message")
    }
}

// MARK: Composer

private struct Composer: View {
    @Binding var text: String
    let placeholder: String
    var focus: FocusState<Bool>.Binding
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

            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused(focus)
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

// MARK: Times

enum ThreadTime {
    private static func startsNewBlock(_ index: Int, in messages: [StewardTask.Message]) -> Bool {
        index == 0 || messages[index].date.timeIntervalSince(messages[index - 1].date) >= 3600
    }

    /// A time opens the thread and any gap of an hour or more.
    static func label(for index: Int, in messages: [StewardTask.Message]) -> Text? {
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
    static func endsGroup(_ index: Int, in messages: [StewardTask.Message]) -> Bool {
        let next = index + 1
        guard next < messages.count else { return true }
        return messages[next].author != messages[index].author || startsNewBlock(next, in: messages)
    }
}
