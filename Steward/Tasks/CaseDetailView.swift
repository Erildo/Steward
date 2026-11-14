import SwiftUI
import StewardCore

/// One errand in full: what's next, what you asked for, and everything Steward did.
struct CaseDetailView: View {
    let file: CaseFile

    var body: some View {
        let kind = ErrandKind(of: file)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(kind)
                NextStep(file: file, tint: kind.deep)
                block("You asked for") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(file.owner.goal)
                            .font(.body)
                            .foregroundStyle(Palette.ink)
                        if !file.standingInstructions.isEmpty {
                            InstructionList(instructions: file.standingInstructions)
                        }
                    }
                }
                if !file.notes.isEmpty {
                    block("Steward's notes") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.notes)
                                .font(.subheadline)
                                .foregroundStyle(Palette.ink)
                                .textSelection(.enabled)
                            Text("Steward keeps these for itself as it works. Nothing in them is hidden from you.")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
                if !file.events.isEmpty {
                    block("What Steward did") { ActivityList(events: file.events) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Palette.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CaseMenu(file: file) } }
    }

    private func header(_ kind: ErrandKind) -> some View {
        HStack(spacing: 14) {
            KindTile(kind: kind, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Palette.ink)
                Text([file.company.name, file.company.country].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func block(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// The one thing that happens next, and who does it. When it's the owner's
/// move, they make it here: approve, edit or decline a draft, or answer.
private struct NextStep: View {
    let file: CaseFile
    let tint: Color

    @Environment(TasksModel.self) private var model
    @State private var showsEditor = false
    @State private var showsNotSorted = false
    @State private var notSortedNote = ""
    @State private var answer = ""
    @FocusState private var answerFocused: Bool

    var body: some View {
        let status = TaskStatus(of: file)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                StatusCircle(status: status, tint: tint, size: 24)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.accessibilityLabel)
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    Text(file.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                }
            }
            details
            if model.working.contains(file.id) {
                Label { Text("Steward is on it…") } icon: { ProgressView().controlSize(.small) }
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            if let problem = model.problems[file.id] {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.ink)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.stewardBubble, in: .rect(cornerRadius: Palette.cardRadius))
        .alert("What's still wrong?", isPresented: $showsNotSorted) {
            TextField("For example, they charged me again", text: $notSortedNote)
            Button("Reopen") {
                model.reportNotSorted(file.id, note: notSortedNote)
                notSortedNote = ""
            }
            Button("Cancel", role: .cancel) { notSortedNote = "" }
        } message: {
            Text("Steward reopens the errand and takes it up with \(file.company.name) again.")
        }
        .sheet(isPresented: $showsEditor) {
            if case .needsApproval(_, let draft) = file.state {
                MessageEditor(text: draft.body) { edited in
                    model.approve(file.id, editedBody: edited == draft.body ? nil : edited)
                }
            }
        }
        .overlay {
            // The orange ring means this needs you, as on chat's approval card.
            if status == .needsYou {
                RoundedRectangle(cornerRadius: Palette.cardRadius + 3)
                    .strokeBorder(Palette.orange, lineWidth: 1.5)
                    .padding(-3)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        switch file.state {
        case .needsApproval(_, let draft):
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                field("To", draft.to)
                field("Subject", draft.subject)
            }
            Text(draft.body)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
            approvalButtons
        case .needsAnswer:
            answerField
        case .closed:
            if let closure = file.closure, !closure.evidence.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("In \(file.company.name)'s words")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                    Text("“\(closure.evidence)”")
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                }
            }
            if file.closure?.status == .done {
                outcome
            }
        default:
            EmptyView()
        }
    }

    private var busy: Bool { model.working.contains(file.id) || !model.canAct }

    /// The second level of proof: the owner's own word that it worked.
    @ViewBuilder
    private var outcome: some View {
        if file.isConfirmedByOwner {
            Label("You confirmed it worked", systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.ink)
        } else if let check = file.outcomeCheck {
            Divider()
            if check.isDue(at: .now) {
                // The question itself is the status line above.
                VStack(alignment: .leading, spacing: 10) {
                    Button { model.markDone(file.id) } label: {
                        Text("Yes, It's Sorted").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.orange)
                    .foregroundStyle(Palette.onOrange)
                    Button { showsNotSorted = true } label: {
                        Text("No, It Isn't").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.ink)
                    .disabled(busy)
                    hint("Your answer counts for more than \(file.company.name)'s email. A no puts Steward back on it.")
                }
                .controlSize(.large)
            } else {
                hint("On \(check.due.formatted(.dateTime.day().month(.wide))), Steward will ask you: \(check.question)")
            }
        }
    }

    private var approvalButtons: some View {
        VStack(spacing: 8) {
            Button { model.approve(file.id) } label: {
                Text("Approve and Send").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.orange)
            .foregroundStyle(Palette.onOrange)
            HStack(spacing: 8) {
                Button { showsEditor = true } label: { Text("Edit and Send").frame(maxWidth: .infinity) }
                Button { model.decline(file.id) } label: { Text("Decline").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            .tint(Palette.ink)
            hint(model.canAct
                 ? (model.isSample ? "Sample: nothing is really sent." : "Nothing is sent without your yes.")
                 : "Steward isn't connected yet, so this can't be sent.")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(busy)
    }

    private var answerField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Your answer", text: $answer, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($answerFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Palette.ground, in: .rect(cornerRadius: 18))
                Button {
                    model.answer(file.id, answer)
                    answer = ""
                    answerFocused = false
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Palette.onOrange)
                        .frame(width: 36, height: 36)
                        .background(Palette.orange, in: .circle)
                }
                .frame(minWidth: 44, minHeight: 44)
                .opacity(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send answer")
            }
            .disabled(busy)
            if !model.canAct {
                hint("Steward isn't connected yet, so it can't carry on.")
            }
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

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Palette.muted)
    }
}

/// What the owner has told Steward along the way. Steward follows these, and
/// they stay beside the goal so a steer is never lost.
private struct InstructionList: View {
    let instructions: [CaseFile.Instruction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What you've told Steward")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            ForEach(Array(instructions.enumerated()), id: \.offset) { _, instruction in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instruction.text)
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                        Text(instruction.date.taskDay)
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The case's activity log, oldest first, in plain language.
private struct ActivityList: View {
    let events: [CaseFile.Event]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Image(systemName: symbol(for: event.kind))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 28, height: 28)
                            .background(Palette.stewardBubble, in: .circle)
                        if index < events.count - 1 {
                            Rectangle()
                                .fill(Palette.muted.opacity(0.25))
                                .frame(width: 1.5)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.readable(event))
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                        Text(event.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The agent logs a close as "<status>: summary" (for example
    /// "needsOwner: …"). The status is shown elsewhere; the owner reads the summary.
    static func readable(_ event: CaseFile.Event) -> String {
        guard event.kind == "closed", let colon = event.detail.range(of: ": "),
              CaseFile.Closure.Status(rawValue: String(event.detail[..<colon.lowerBound])) != nil
        else { return event.detail }
        return String(event.detail[colon.upperBound...])
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "opened": "flag"
        case "email_out": "paperplane"
        case "email_in": "envelope"
        case "approval_asked": "hand.raised"
        case "owner_edited": "pencil"
        case "owner_declined": "xmark"
        case "owner_took_over": "hand.raised"
        case "owner_stopped": "stop.circle"
        case "owner_confirmed": "checkmark.seal.fill"
        case "owner_answer": "text.bubble"
        case "ask_owner": "questionmark.bubble"
        case "waiting", "wait": "clock"
        case "gate_block": "shield"
        case "closed": "checkmark.seal"
        case "close_rejected", "review_rejected": "arrow.uturn.backward"
        case "reopened": "arrow.counterclockwise"
        case "send_failed": "exclamationmark.triangle"
        case "wake_failed": "exclamationmark.triangle"
        default: "circle"
        }
    }
}

/// The owner's own moves on an errand, beside Steward's: take it over,
/// stop it, or say it's sorted.
private struct CaseMenu: View {
    let file: CaseFile

    @Environment(TasksModel.self) private var model

    var body: some View {
        let status = TaskStatus(of: file)
        Menu {
            if status == .onIt, file.isOverdue, model.canAct {
                Button("Follow Up Now", systemImage: "arrow.clockwise") { model.nudge(file.id) }
            }
            if [.needsYou, .onIt, .yours].contains(status) {
                Button("Mark Done", systemImage: "checkmark.circle") { model.markDone(file.id) }
            }
            if status == .done, !file.isConfirmedByOwner {
                Button("Confirm It's Sorted", systemImage: "checkmark.seal") { model.markDone(file.id) }
            }
            if [.needsYou, .onIt].contains(status), file.state != .closed {
                Button("Take Over", systemImage: "hand.raised") { model.takeOver(file.id) }
                Divider()
                Button("Stop Errand", systemImage: "stop.circle", role: .destructive) { model.stop(file.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Errand actions")
        .disabled(status == .stopped || (status == .done && file.isConfirmedByOwner))
    }
}
