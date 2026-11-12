import SwiftUI
import StewardCore

/// Every errand as a task, grouped by who acts next: you, Steward, or nobody.
struct TasksView: View {
    @State private var model = TasksModel.launch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .background(Palette.ground)
                .navigationTitle("Tasks")
                .navigationDestination(for: UUID.self) { id in
                    if let file = model.file(id) { CaseDetailView(file: file) }
                }
        }
        .environment(model)
        .onAppear { model.reload() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.cases.isEmpty && !model.couldNotRead {
            ContentUnavailableView(
                "No errands yet",
                systemImage: "checkmark.circle",
                description: Text("Tell Steward what needs sorting in Chat. It shows up here, and stays until it's done.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if model.couldNotRead {
                        Label("Steward couldn't read some of your errands.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                    }
                    section("Needs you", model.needsYou)
                    section("Steward is on it", model.onIt)
                    section("Done", model.finished)
                    if model.isSample {
                        Text("Sample errands: nothing here is real.")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable { model.reload() }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ files: [CaseFile]) -> some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("\(files.count)").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                ForEach(files) { file in
                    NavigationLink(value: file.id) { TaskRow(file: file) }
                        .buttonStyle(TaskRowButtonStyle())
                }
            }
        }
    }
}

/// One errand: its kind on the left, where it stands in the middle, and a
/// circle on the right saying who acts next.
struct TaskRow: View {
    let file: CaseFile

    var body: some View {
        let kind = ErrandKind(of: file)
        let status = TaskStatus(of: file)
        let finished = status == .done || status == .stopped

        HStack(spacing: 14) {
            KindTile(kind: kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(file.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(finished ? Palette.muted : kind.deep)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusCircle(status: status, tint: kind.deep)
        }
        .padding(.vertical, 14)
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .background(finished ? Palette.stewardBubble : kind.wash, in: .rect(cornerRadius: Palette.cardRadius))
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.accessibilityLabel)
    }
}

private struct TaskRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct KindTile: View {
    let kind: ErrandKind
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(kind.deep)
            .frame(width: size, height: size)
            .background(kind.tile, in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

/// The circle on the right. Orange means it waits for you; a slowly turning
/// dashed ring means Steward is on it; filled means done.
struct StatusCircle: View {
    let status: TaskStatus
    let tint: Color
    var size: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch status {
            case .needsYou:
                Circle().strokeBorder(Palette.orange, lineWidth: 2.5)
                Circle().fill(Palette.orange).frame(width: size * 0.32, height: size * 0.32)
            case .onIt:
                if reduceMotion {
                    dashedRing
                } else {
                    TimelineView(.animation) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 14) / 14
                        dashedRing.rotationEffect(.degrees(turn * 360))
                    }
                }
            case .done:
                Circle().fill(Palette.ink)
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Palette.ground)
            case .stopped:
                Circle().strokeBorder(Palette.muted.opacity(0.7), lineWidth: 2)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var dashedRing: some View {
        Circle()
            .inset(by: 1.25)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3.2, 4.6]))
    }
}

/// The four errands Steward focuses on, each with its own soft colour, so a
/// glance tells them apart. Orange stays reserved for what needs you.
enum ErrandKind {
    case cancel, dispute, refund, complain, other

    init(of file: CaseFile) {
        let key = (file.playbook ?? "") + " " + file.errand.lowercased()
        if key.hasPrefix("cancel") || key.contains("cancel") { self = .cancel }
        else if key.hasPrefix("dispute") || key.contains("dispute") { self = .dispute }
        else if key.hasPrefix("refund") || key.contains("refund") { self = .refund }
        else if key.hasPrefix("complain") || key.contains("complain") { self = .complain }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .cancel: "scissors"
        case .dispute: "exclamationmark.bubble"
        case .refund: "arrow.uturn.backward"
        case .complain: "megaphone"
        case .other: "tray"
        }
    }

    /// The row's background.
    var wash: Color {
        switch self {
        case .cancel: Palette.dynamic(light: 0xEBF1FB, dark: 0x151C29)
        case .dispute: Palette.dynamic(light: 0xFBEEF0, dark: 0x27181C)
        case .refund: Palette.dynamic(light: 0xEBF6EE, dark: 0x14221A)
        case .complain: Palette.dynamic(light: 0xF2EEFA, dark: 0x1D1829)
        case .other: Palette.stewardBubble
        }
    }

    /// The icon tile, a step deeper than the wash.
    var tile: Color {
        switch self {
        case .cancel: Palette.dynamic(light: 0xD4E1F7, dark: 0x23314B)
        case .dispute: Palette.dynamic(light: 0xF6D7DC, dark: 0x45262D)
        case .refund: Palette.dynamic(light: 0xD3EDDB, dark: 0x203A2A)
        case .complain: Palette.dynamic(light: 0xE2DAF5, dark: 0x332A4A)
        case .other: Palette.dynamic(light: 0xE0E0E5, dark: 0x262B36)
        }
    }

    /// Icons and secondary text on the wash.
    var deep: Color {
        switch self {
        case .cancel: Palette.dynamic(light: 0x2D4E86, dark: 0xB7CCF2)
        case .dispute: Palette.dynamic(light: 0x8A3341, dark: 0xF0BCC5)
        case .refund: Palette.dynamic(light: 0x2F6B45, dark: 0xB6E2C4)
        case .complain: Palette.dynamic(light: 0x5A4594, dark: 0xCDBFF2)
        case .other: Palette.muted
        }
    }
}
