import SwiftUI

private extension View {
    func card() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.stewardBubble, in: .rect(cornerRadius: Palette.cardRadius))
    }
}

struct MessageAttachmentView: View {
    let attachment: ChatMessage.Attachment

    @Environment(ChatModel.self) private var model

    var body: some View {
        switch attachment {
        case .progress(let id):
            if let errand = model.errands[id] { ProgressCard(errand: errand) }
        case .deadline(let info):
            DeadlineCard(info: info)
        case .approval(let id):
            if let errand = model.errands[id] { ApprovalCard(errand: errand) }
        }
    }
}

struct StepList: View {
    let steps: [Errand.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 10) {
                    icon(for: step.state).frame(width: 22, height: 22)
                    Text(step.title)
                        .font(.subheadline.weight(step.state == .active || step.state == .waiting ? .semibold : .regular))
                        .foregroundStyle(step.state == .pending ? Palette.muted : Palette.ink)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(label(for: step.state))
            }
        }
    }

    @ViewBuilder
    private func icon(for state: Errand.StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.muted)
        case .active:
            ProgressView().controlSize(.small)
        case .waiting:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(Palette.orange)
        case .pending:
            Image(systemName: "circle").foregroundStyle(Palette.muted.opacity(0.6))
        }
    }

    private func label(for state: Errand.StepState) -> String {
        switch state {
        case .done: "Done"
        case .active: "In progress"
        case .waiting: "Waiting for you"
        case .pending: "Not started"
        }
    }
}

private struct ProgressCard: View {
    let errand: Errand

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(errand.title).font(.headline).foregroundStyle(Palette.ink)
                Spacer()
                Text("Demo").font(.caption).foregroundStyle(Palette.muted)
            }
            StepList(steps: errand.steps)
        }
        .card()
    }
}

private struct DeadlineCard: View {
    let info: DeadlineInfo

    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(info.daysLeft) days left to cancel")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.muted.opacity(0.3))
                    Capsule().fill(Palette.ink).frame(width: proxy.size.width * info.elapsedFraction)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                row(day(info.lastDay), "Last day to cancel")
                row(day(info.nextPayment), "Next payment, \(info.amount)")
            }
        }
        .card()
    }

    private func row(_ date: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).foregroundStyle(Palette.ink)
            Spacer()
            Text(date).foregroundStyle(Palette.muted)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

private struct ApprovalCard: View {
    let errand: Errand

    @Environment(ChatModel.self) private var model
    @State private var showsEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                field("To", errand.recipient)
                field("Subject", errand.subject)
            }
            Divider()
            Text(errand.messageBody)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
            outcome
        }
        .card()
        .overlay {
            // The orange ring means this needs you.
            if errand.approval == .pending {
                RoundedRectangle(cornerRadius: Palette.cardRadius + 3)
                    .strokeBorder(Palette.orange, lineWidth: 1.5)
                    .padding(-3)
            }
        }
        .sheet(isPresented: $showsEditor) {
            MessageEditor(text: errand.messageBody) { model.updateMessageBody($0, for: errand.id) }
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
    private var outcome: some View {
        switch errand.approval {
        case .pending:
            VStack(spacing: 8) {
                Button { model.approve(errand.id) } label: {
                    Text("Approve and Send").font(.body.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.orange)
                .foregroundStyle(Palette.onOrange)
                HStack(spacing: 8) {
                    Button { showsEditor = true } label: { Text("Edit").frame(maxWidth: .infinity) }
                    Button { model.decline(errand.id) } label: { Text("Decline").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered)
                .tint(Palette.ink)
            }
            .controlSize(.large)
            Text("Demo: nothing is really sent.")
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
        case .approved:
            Label("You approved this", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
        case .declined:
            Label("Not sent", systemImage: "xmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.muted)
        case .notAsked:
            EmptyView()
        }
    }
}

private struct MessageEditor: View {
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
