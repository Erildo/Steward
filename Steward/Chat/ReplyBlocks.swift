import SwiftUI
import StewardCore

// MARK: Palette for tickets

extension Palette {
    /// The paper a ticket is printed on: white on white, held by its edge in
    /// light; a step up from the ground in dark.
    static let ticket = dynamic(light: 0xFFFFFF, dark: 0x151922)
    /// The ticket's one-pixel edge and its tear line.
    static let ticketEdge = dynamic(light: 0xDCDCE2, dark: 0x2B3140)
}

// MARK: Where a block sits

/// Everything a block needs from the thread it sits in.
struct BlockContext {
    let conversationID: UUID
    let messageID: UUID
    /// Steward's newest message, with nothing after it: prompts are live.
    let isLatest: Bool
    /// Steward is busy here, so prompts wait.
    let isBusy: Bool
    /// The errand behind the steps is running now, so spinners may turn.
    let isRunning: Bool
}

extension ReplyBlock {
    /// Choices and fields are the owner's answers, not Steward's words: they
    /// sit on the owner's side and only while they can still be used.
    var isPrompt: Bool {
        switch self {
        case .choices, .field: true
        default: false
        }
    }
}

/// One block, drawn natively.
struct ReplyBlockView: View {
    let block: ReplyBlock
    let context: BlockContext
    /// Sends the owner's words, as if typed.
    let answer: (String) -> Void

    var body: some View {
        switch block {
        case .choices(let v): ChoicesView(choices: v, answer: answer)
        case .field(let v): FieldView(field: v, answer: answer)
        case .steps(let v): StepsTicket(steps: v, isRunning: context.isRunning)
        case .deadline(let v): DeadlineTicket(deadline: v)
        case .draft(let v): DraftTicket(draft: v, context: context)
        case .compare(let v): CompareTicket(compare: v)
        case .timeline(let v): TimelineTicket(timeline: v)
        case .proof(let v): ProofTicket(proof: v)
        }
    }
}

// MARK: The ticket

/// Steward's cards read like a ticket it hands you: paper with a hairline
/// edge, a stub naming what it is and where it stands, and, when there is
/// something to do, a torn line before the actions.
struct Ticket<Content: View, Actions: View>: View {
    let kind: String
    var status: String?
    /// The status asks for the owner: it reads in orange, with a hand.
    var needsYou = false
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    private let inset: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stub
                .padding(.bottom, 12)
            content
            if Actions.self != EmptyView.self {
                TearLine(inset: inset)
                    .padding(.vertical, 14)
                actions
            }
        }
        .padding(inset)
        .frame(maxWidth: 520, alignment: .leading)
        // The edge sits under the content, so the tear line's punches can bite
        // into it. It stays grey: the thread's one orange ring does the pointing.
        .background {
            RoundedRectangle(cornerRadius: Palette.cardRadius)
                .fill(Palette.ticket)
                .strokeBorder(Palette.ticketEdge, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var stub: some View {
        HStack(alignment: .center, spacing: 7) {
            StewardAvatar(size: 18, blinks: false)
            Text(kind)
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.orangeText)
            Spacer(minLength: 8)
            if let status {
                HStack(spacing: 4) {
                    if needsYou { Image(systemName: "hand.raised.fill").imageScale(.small) }
                    Text(status)
                }
                .font(.caption.weight(needsYou ? .semibold : .medium))
                .foregroundStyle(needsYou ? Palette.orangeText : Palette.muted)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Ticket where Actions == EmptyView {
    init(kind: String, status: String? = nil, needsYou: Bool = false, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.status = status
        self.needsYou = needsYou
        self.content = content()
        self.actions = EmptyView()
    }
}

/// The perforation: a dashed line with a punched notch at each edge.
private struct TearLine: View {
    let inset: CGFloat
    private let notch: CGFloat = 7

    var body: some View {
        ZStack {
            Line()
                .stroke(Palette.ticketEdge, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 1)
                .padding(.horizontal, notch + 4)
            HStack {
                punch(facing: 0)
                Spacer()
                punch(facing: 180)
            }
        }
        .frame(height: notch * 2)
        .padding(.horizontal, -inset)
        .accessibilityHidden(true)
    }

    /// A half circle bitten out of the edge: ground fills it, and the edge
    /// line follows its curve on the paper side.
    private func punch(facing degrees: Double) -> some View {
        ZStack {
            Circle().fill(Palette.ground)
            Circle()
                .trim(from: 0, to: 0.5)
                .stroke(Palette.ticketEdge, lineWidth: 1)
                .rotationEffect(.degrees(degrees - 90))
        }
        .frame(width: notch * 2, height: notch * 2)
        .offset(x: degrees == 0 ? -notch : notch)
    }
}

private struct Line: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: Prompts: the owner's side

/// Short answers to tap. They're the owner's words-to-be, so they wear the
/// owner's orange and sit on the owner's side.
private struct ChoicesView: View {
    let choices: ReplyBlock.Choices
    let answer: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8, alignment: .trailing) {
            ForEach(choices.options, id: \.self) { option in
                Button { answer(option) } label: {
                    Text(option)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.orangeText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .overlay { Capsule().strokeBorder(Palette.orange, lineWidth: 1.5) }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityHint("Sends this as your answer")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .sensoryFeedback(.selection, trigger: choices)
    }
}

/// One value, typed in place, with the keyboard and autofill that fit it.
private struct FieldView: View {
    let field: ReplyBlock.Field
    let answer: (String) -> Void

    @State private var value = ""
    @FocusState private var focused: Bool

    private var canSend: Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(field.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.muted)
                .padding(.trailing, 16)
            HStack(spacing: 4) {
                input
                    .focused($focused)
                    .tint(Palette.orange)
                    .foregroundStyle(Palette.ink)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Palette.onOrange)
                        .frame(width: 34, height: 34)
                        .background(Palette.orange.opacity(canSend ? 1 : 0.35), in: .circle)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send \(field.label)")
            }
            .padding(.trailing, 2)
            .background(Palette.ticket, in: .capsule)
            .overlay { Capsule().strokeBorder(Palette.orange, lineWidth: 1.5) }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var input: some View {
        let field = TextField(self.field.placeholder ?? self.field.label, text: $value)
            .accessibilityLabel(self.field.label)
        switch self.field.kind {
        case .email:
            field.keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        case .phone:
            field.keyboardType(.phonePad).textContentType(.telephoneNumber)
        case .number:
            field.keyboardType(.decimalPad)
        case .date, .text:
            field
        }
    }

    private func send() {
        guard canSend else { return }
        answer(value)
        value = ""
        focused = false
    }
}

// MARK: Tickets

private struct StepsTicket: View {
    let steps: ReplyBlock.Steps
    let isRunning: Bool

    private var status: (String, Bool) {
        if steps.steps.allSatisfy({ $0.state == .done }) { return ("Done", false) }
        if steps.steps.contains(where: { $0.state == .waiting }) { return (isRunning ? "Needs you" : "Paused", isRunning) }
        if let index = steps.steps.firstIndex(where: { $0.state == .active }) {
            return (isRunning ? "Step \(index + 1) of \(steps.steps.count)" : "Paused", false)
        }
        let done = steps.steps.filter { $0.state == .done }.count
        return (done == 0 ? "Not started" : "Stopped after \(done)", false)
    }

    var body: some View {
        Ticket(kind: "Errand", status: status.0, needsYou: status.1) {
            VStack(alignment: .leading, spacing: 12) {
                Text(steps.title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                StepList(steps: steps.steps, isRunning: isRunning)
            }
        }
    }
}

/// Steps with what state each is in, joined by a thin rail.
struct StepList: View {
    let steps: [ReplyBlock.Steps.Step]
    var isRunning = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        icon(for: step.state).frame(width: 22, height: 22)
                        if index < steps.count - 1 {
                            Rectangle()
                                .fill(step.state == .done ? Palette.muted.opacity(0.6) : Palette.ticketEdge)
                                .frame(width: 1.5)
                                .frame(minHeight: 10, maxHeight: .infinity)
                        }
                    }
                    Text(step.title)
                        .font(.subheadline.weight(step.state == .active || step.state == .waiting ? .semibold : .regular))
                        .foregroundStyle(step.state == .pending ? Palette.muted : Palette.ink)
                        .padding(.top, 2)
                        .padding(.bottom, index < steps.count - 1 ? 12 : 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(label(for: step.state))
            }
        }
    }

    @ViewBuilder
    private func icon(for state: ReplyBlock.Steps.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ink)
        case .active where isRunning:
            ProgressView().controlSize(.small)
        case .active:
            Image(systemName: "pause.circle").foregroundStyle(Palette.muted)
        case .waiting:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(isRunning ? Palette.orange : Palette.muted)
        case .pending:
            Image(systemName: "circle").foregroundStyle(Palette.muted.opacity(0.6))
        }
    }

    private func label(for state: ReplyBlock.Steps.State) -> String {
        switch state {
        case .done: "Done"
        case .active: isRunning ? "In progress" : "Paused"
        case .waiting: "Waiting for you"
        case .pending: "Not started"
        }
    }
}

private struct DeadlineTicket: View {
    let deadline: ReplyBlock.Deadline

    var body: some View {
        Ticket(kind: "Deadline") {
            VStack(alignment: .leading, spacing: 12) {
                Text(deadline.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.ink)
                if let progress = deadline.progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.ticketEdge)
                            Capsule().fill(Palette.ink).frame(width: max(proxy.size.width * progress, 6))
                        }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                }
                if !deadline.rows.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(deadline.rows.enumerated()), id: \.offset) { _, row in
                            RowView(row: row)
                        }
                    }
                }
            }
        }
    }
}

private struct RowView: View {
    let row: ReplyBlock.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(row.label).foregroundStyle(Palette.ink)
            Spacer(minLength: 12)
            Text(row.value)
                .monospacedDigit()
                .fontWeight(.semibold)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

private struct DraftTicket: View {
    let draft: ReplyBlock.Draft
    let context: BlockContext

    @Environment(ChatModel.self) private var chat
    @State private var showsEditor = false

    private var isLive: Bool { chat.isLive(draft, message: context.messageID, in: context.conversationID) }

    private var status: String {
        switch draft.status {
        case .pending: isLive ? "Needs your OK" : "No longer waiting"
        case .approved: chat.sendsForReal(draft) ? "Sent" : "Approved"
        case .declined: "Not sent"
        }
    }

    var body: some View {
        Ticket(kind: "Email", status: status, needsYou: isLive) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    field("To", draft.to)
                    field("Subject", draft.subject)
                }
                Rectangle().fill(Palette.ticketEdge).frame(height: 1)
                Text(draft.body)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
            }
        } actions: {
            actions
        }
        .sensoryFeedback(.success, trigger: draft.status) { _, new in new == .approved }
        .sheet(isPresented: $showsEditor) {
            MessageEditor(text: draft.body) { chat.editDraft(message: context.messageID, in: context.conversationID, body: $0) }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(Palette.muted)
            Text(value).foregroundStyle(Palette.ink)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        switch draft.status {
        case .pending where isLive:
            VStack(spacing: 8) {
                Button { chat.approve(message: context.messageID, in: context.conversationID) } label: {
                    Text(chat.sendsForReal(draft) ? "Approve and Send" : "Approve").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.orange)
                .foregroundStyle(Palette.onOrange)
                HStack(spacing: 8) {
                    Button { showsEditor = true } label: { Text("Edit").frame(maxWidth: .infinity) }
                    Button { chat.decline(message: context.messageID, in: context.conversationID) } label: { Text("Decline").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered)
                .tint(Palette.ink)
                if !chat.sendsForReal(draft) {
                    Text(draft.caseID == nil ? "Demo: nothing is really sent." : "Simulated: nothing is really sent.")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        case .pending:
            Text("This draft was never sent. Ask Steward to pick the errand up again.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
        case .approved:
            Label(chat.sendsForReal(draft) ? "You approved it, and it went out" : "You approved this", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
        case .declined:
            Label("You declined it. Nothing went out.", systemImage: "xmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.muted)
        }
    }
}

private struct CompareTicket: View {
    let compare: ReplyBlock.Compare

    var body: some View {
        Ticket(kind: "Compare", status: "\(compare.options.count) options") {
            VStack(alignment: .leading, spacing: 12) {
                Text(compare.title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                VStack(spacing: 0) {
                    ForEach(Array(compare.options.enumerated()), id: \.offset) { index, option in
                        if index > 0 { Rectangle().fill(Palette.ticketEdge).frame(height: 1) }
                        row(option)
                    }
                }
            }
        }
    }

    private func row(_ option: ReplyBlock.Compare.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    if option.isPick {
                        Label("Pick", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Palette.orangeText)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Text(option.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let price = option.price {
                Text(price)
                    .font(.subheadline.weight(option.isPick ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.isPick ? "Steward's pick: \(option.name)" : option.name)
    }
}

private struct TimelineTicket: View {
    let timeline: ReplyBlock.Timeline

    @ScaledMetric(relativeTo: .caption) private var whenWidth: CGFloat = 52

    var body: some View {
        Ticket(kind: "Plan", status: "\(timeline.items.count) steps") {
            VStack(alignment: .leading, spacing: 12) {
                Text(timeline.title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(timeline.items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .top, spacing: 10) {
                            Text(item.when ?? "")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Palette.muted)
                                .frame(width: whenWidth, alignment: .leading)
                                .padding(.top, 2)
                            VStack(spacing: 0) {
                                Circle().fill(Palette.ink).frame(width: 7, height: 7).padding(.top, 6)
                                if index < timeline.items.count - 1 {
                                    Rectangle().fill(Palette.ticketEdge).frame(width: 1.5).frame(maxHeight: .infinity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Palette.ink)
                                if let detail = item.detail {
                                    Text(detail)
                                        .font(.footnote)
                                        .foregroundStyle(Palette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.bottom, index < timeline.items.count - 1 ? 14 : 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct ProofTicket: View {
    let proof: ReplyBlock.Proof

    private var shareText: String {
        [proof.headline, proof.detail, proof.quote.map { "“\($0)”" }, proof.source.map { "— \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        Ticket(kind: "Proof", status: proof.date.map { $0.formatted(.dateTime.month(.abbreviated).day()) }) {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(proof.headline).font(.title3.weight(.bold))
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.ink)
                }
                .foregroundStyle(Palette.ink)
                if let detail = proof.detail {
                    Text(detail).font(.subheadline).foregroundStyle(Palette.ink)
                }
                if let quote = proof.quote {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“\(quote)”")
                            .font(.subheadline)
                            .italic()
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                        if let source = proof.source {
                            Text("— \(source)")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.row, in: .rect(cornerRadius: 10))
                }
            }
        } actions: {
            ShareLink(item: shareText) {
                Label("Share Proof", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .tint(Palette.ink)
        }
    }
}

// MARK: Layout

/// Lays chips out in rows, wrapping when the next one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: Editing a draft

struct MessageEditor: View {
    @State var text: String
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal, 12)
                .navigationTitle("Edit Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
