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
                    Text(file.owner.goal)
                        .font(.body)
                        .foregroundStyle(Palette.ink)
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
    }

    private func header(_ kind: ErrandKind) -> some View {
        HStack(spacing: 14) {
            KindTile(kind: kind, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.errand)
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

/// The one thing that happens next, and who does it.
private struct NextStep: View {
    let file: CaseFile
    let tint: Color

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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.stewardBubble, in: .rect(cornerRadius: Palette.cardRadius))
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
            hint("Approve, edit or decline it in Chat. Nothing is sent without your yes.")
        case .needsAnswer:
            hint("Answer in Chat and Steward carries on.")
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
        default:
            EmptyView()
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
                        Text(event.detail)
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

    private func symbol(for kind: String) -> String {
        switch kind {
        case "opened": "flag"
        case "email_out": "paperplane"
        case "email_in": "envelope"
        case "approval_asked": "hand.raised"
        case "owner_edited": "pencil"
        case "owner_declined": "xmark"
        case "owner_answer": "text.bubble"
        case "ask_owner": "questionmark.bubble"
        case "waiting", "wait": "clock"
        case "gate_block": "shield"
        case "closed": "checkmark.seal"
        case "close_rejected": "arrow.uturn.backward"
        case "wake_failed": "exclamationmark.triangle"
        default: "circle"
        }
    }
}
