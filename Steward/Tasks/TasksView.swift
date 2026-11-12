import SwiftUI
import StewardCore

/// Two lists behind one switch: what you handed to Steward, grouped by who
/// acts next, and your own to-dos.
struct TasksView: View {
    @Bindable var model: TasksModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [UUID] = []
    /// The add sheet, with what it opens with.
    @State private var adding: AddRequest?
    @State private var showsProfile = false
    @State private var showsArchive = false
    /// Which list shows. Yours first; remembered between launches.
    @AppStorage("tasks.list") private var scope = TaskScope.mine
    /// Sections the owner folded away, per list. Done starts folded in both.
    @AppStorage("tasks.folded") private var foldedRaw = "mine.done,steward.done"
    /// Sections showing every row, past the first few.
    @State private var expandedFully: Set<String> = []

    /// Rows a section shows before "Show more".
    private static let rowLimit = 5

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Palette.ground)
                .navigationTitle("Tasks")
                .toolbar { toolbar }
                .navigationDestination(for: UUID.self) { id in
                    if let file = model.file(id) {
                        CaseDetailView(file: file)
                    } else if model.stewardTask(id) != nil {
                        StewardTaskDetail(id: id)
                    } else {
                        OwnerTaskDetail(id: id)
                    }
                }
                .navigationDestination(isPresented: $showsArchive) { ArchiveView(scope: scope) }
                .overlay(alignment: .bottom) { UndoToast() }
        }
        .environment(model)
        .sheet(item: $adding) { request in
            AddTaskSheet(request: request) { id in path = [id] }
        }
        .sheet(isPresented: $showsProfile) { ProfileSheet() }
        .onAppear { model.reload() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.reload() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showsProfile = true } label: { OwnerAvatar(size: 30) }
                .accessibilityLabel("Your profile")
        }
        ToolbarItem(placement: .topBarTrailing) {
            // The plus adds to the list you're looking at.
            Button { adding = AddRequest(doer: scope == .steward ? .steward : .me) } label: { Image(systemName: "plus") }
                .accessibilityLabel(scope == .steward ? "Ask Steward" : "New task")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty && !model.couldNotRead {
            EmptyTasks(add: { adding = $0 })
        } else {
            List {
                if model.couldNotRead {
                    Section {
                        HStack(spacing: 12) {
                            Label("Steward couldn't read some of your tasks.", systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(Palette.ink)
                            Spacer(minLength: 0)
                            Button("Retry") { model.reload() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .listRowBackground(Palette.row)
                }
                Section {
                    ScopePicker(scope: $scope)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                switch scope {
                case .steward: stewardList
                case .mine: mineList
                }
                if !model.query.isEmpty, model.matchCount(in: scope) == 0 {
                    noMatches
                }
                if model.isSample {
                    Text("Sample tasks: nothing here is real.")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .scrollContentBackground(.hidden)
            .refreshable { model.reload() }
            .animation(.snappy(duration: 0.25), value: foldedRaw)
            // Always there once you have tasks, so the layout never jumps.
            .searchable(text: $model.query, prompt: scope == .steward ? "Search Steward's tasks" : "Search your tasks")
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var stewardList: some View {
        if model.query.isEmpty, !model.hasItems(in: .steward) {
            ListEmpty(
                title: "Nothing with Steward",
                message: "Hand Steward anything: a subscription to cancel, a refund to chase, a trip to plan.",
                action: "Ask Steward"
            ) { adding = AddRequest(doer: .steward) }
        } else {
            if let calm = calmLine {
                Label(calm, systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            section(.needsYou, model.needsYou)
            section(.backToYou, model.handedBack)
            section(.stewards, model.stewards, footer: model.canAct ? nil : "Steward isn't connected yet, so these are paused.")
            doneSection
        }
    }

    @ViewBuilder
    private var mineList: some View {
        // Your list never hides that Steward is waiting on you.
        if model.query.isEmpty, model.needsYouCount > 0 {
            Section {
                Button { scope = .steward } label: {
                    HStack(spacing: 12) {
                        StewardAvatar(size: 28, blinks: false)
                        Text(model.needsYouCount == 1 ? "Steward needs you on 1 task" : "Steward needs you on \(model.needsYouCount) tasks")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(minHeight: 32)
                }
                .accessibilityHint("Shows Steward's list")
            }
            .listRowBackground(Palette.row)
        }
        section(.yours, model.mine, alwaysShown: model.query.isEmpty) {
            Button { adding = AddRequest() } label: {
                Label("New Task", systemImage: "plus")
                    .font(.body)
                    .foregroundStyle(Palette.orangeText)
                    .frame(minHeight: 32)
            }
        }
        doneSection
    }

    /// Done for the list showing, with the way into its archive.
    private var doneSection: some View {
        let done = model.done.filter(scope.contains)
        let archived = model.archived.filter(scope.contains)
        return section(.done, done, footer: done.isEmpty ? nil : "Done tasks move to the archive after 30 days.") {
            if !archived.isEmpty {
                Button { showsArchive = true } label: {
                    HStack {
                        Label("Archive", systemImage: "archivebox")
                        Spacer()
                        Text("\(archived.count)").monospacedDigit().foregroundStyle(Palette.muted)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.muted)
                    }
                    .foregroundStyle(Palette.ink)
                }
            }
        }
    }

    /// One reassuring line when Steward isn't waiting on you.
    private var calmLine: String? {
        guard model.query.isEmpty, model.needsYou.isEmpty, model.handedBack.isEmpty, !model.couldNotRead else { return nil }
        let onIt = model.stewards.count
        return onIt > 0 ? "Nothing needs you. Steward has \(onIt) on the go." : "Nothing needs you."
    }

    /// No match here; if the other list has some, one tap goes there.
    @ViewBuilder
    private var noMatches: some View {
        let other: TaskScope = scope == .steward ? .mine : .steward
        let elsewhere = model.matchCount(in: other)
        VStack(spacing: 10) {
            Text("No tasks match “\(model.query)” in \(scope.title).")
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            if elsewhere > 0 {
                Button(elsewhere == 1 ? "Show 1 in \(other.title)" : "Show \(elsewhere) in \(other.title)") { scope = other }
                    .buttonStyle(.bordered)
                    .tint(Palette.ink)
            }
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    // MARK: Sections

    private var folded: Set<String> {
        Set(foldedRaw.split(separator: ",").map(String.init))
    }

    /// Folding is per list, so Done can stay open in one and shut in the other.
    private func key(_ section: TaskSection) -> String { "\(scope.rawValue).\(section.rawValue)" }

    private func toggle(_ section: TaskSection) {
        var set = folded
        let key = key(section)
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        foldedRaw = set.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private func section(
        _ kind: TaskSection, _ items: [TaskItem],
        alwaysShown: Bool = false, footer: String? = nil,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        if !items.isEmpty || alwaysShown {
            // While searching, every match shows.
            let isFolded = folded.contains(key(kind)) && model.query.isEmpty
            let full = expandedFully.contains(key(kind)) || !model.query.isEmpty
            let shown = full ? items : Array(items.prefix(Self.rowLimit))
            Section {
                if !isFolded {
                    ForEach(shown) { item in
                        // In your own list every row is yours, so the avatar says nothing.
                        NavigationLink(value: item.id) { TaskRow(item: item, showsAvatar: scope == .steward) }
                            .modifier(TaskActions(item: item, handToSteward: handToSteward))
                    }
                    if items.count > shown.count {
                        Button("Show \(items.count - shown.count) More") {
                            withAnimation(.snappy) { _ = expandedFully.insert(key(kind)) }
                        }
                        .foregroundStyle(Palette.orangeText)
                    }
                    trailing()
                }
            } header: {
                SectionHeader(title: kind.title, count: items.count, folded: isFolded) { toggle(kind) }
            } footer: {
                if let footer, !isFolded { Text(footer) }
            }
            .listRowBackground(Palette.row)
        }
    }

    private func handToSteward(_ task: OwnerTask) {
        model.handToSteward(task.id)
    }
}

enum TaskSection: String, Hashable {
    case needsYou, backToYou, stewards, yours, done

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .backToYou: "Back with you"
        case .stewards: "Steward is on it"
        case .yours: "To do"
        case .done: "Done"
        }
    }
}

/// The switch between your list and Steward's, first thing under the title.
/// Each side carries its face, so you know which is which without reading.
/// The system segmented control can't hold an avatar, so this draws its own
/// and hands VoiceOver the real one.
private struct ScopePicker: View {
    @Binding var scope: TaskScope

    @Environment(TasksModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb
    @ScaledMetric(relativeTo: .subheadline) private var face: CGFloat = 24

    /// The raised pill under the chosen side.
    private static let thumbFill = Palette.dynamic(light: 0xFFFFFF, dark: 0x2A303C)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TaskScope.allCases) { option in
                // Borderless, so each side keeps its own tap inside the list row.
                Button { choose(option) } label: { segment(option) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(3)
        .background(Palette.row, in: .capsule)
        .sensoryFeedback(.selection, trigger: scope)
        .accessibilityRepresentation {
            Picker("List", selection: $scope) {
                ForEach(TaskScope.allCases) { option in
                    Text(accessibilityLabel(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ option: TaskScope) -> some View {
        let chosen = option == scope
        return HStack(spacing: 8) {
            avatar(option)
            Text(option.title)
                .font(.subheadline.weight(chosen ? .semibold : .medium))
                .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                .lineLimit(1)
            if option == .steward, model.needsYouCount > 0 {
                Text("\(model.needsYouCount)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Palette.onOrange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Palette.orange, in: .capsule)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background {
            if chosen {
                Capsule()
                    .fill(Self.thumbFill)
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    .matchedGeometryEffect(id: "thumb", in: thumb)
            }
        }
        .contentShape(.capsule)
    }

    @ViewBuilder
    private func avatar(_ option: TaskScope) -> some View {
        Group {
            switch option {
            case .mine: OwnerAvatar(size: face)
            case .steward: StewardAvatar(size: face, blinks: false)
            }
        }
        // Quieter when it isn't the list showing.
        .opacity(option == scope ? 1 : 0.7)
        .accessibilityHidden(true)
    }

    private func choose(_ option: TaskScope) {
        guard option != scope else { return }
        if reduceMotion {
            scope = option
        } else {
            withAnimation(.snappy(duration: 0.28)) { scope = option }
        }
    }

    private func accessibilityLabel(_ option: TaskScope) -> String {
        guard option == .steward, model.needsYouCount > 0 else { return option.title }
        return "\(option.title), \(model.needsYouCount) need you"
    }
}

/// One list is empty while the other isn't: say so, and offer the way in.
private struct ListEmpty: View {
    let title: String
    let message: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Button(action: perform) { Text(action) }
                .buttonStyle(.borderedProminent)
                .tint(Palette.orange)
                .foregroundStyle(Palette.onOrange)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }
}

/// A section title you can tap to fold the section away.
private struct SectionHeader: View {
    let title: String
    let count: Int
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.ink)
                Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                    .rotationEffect(.degrees(folded ? -90 : 0))
            }
            .contentShape(.rect)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.horizontal, -4)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(folded ? "Collapsed" : "Expanded")
        .accessibilityHint(folded ? "Shows this section" : "Hides this section")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Rows

/// One task: who acts next on the left, what it is and where it stands in the
/// middle, and on your own tasks a circle to tick it off.
struct TaskRow: View {
    let item: TaskItem
    var showsAvatar = true

    @Environment(TasksModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        if showsAvatar { TaskAvatar(item: item) }
                        Spacer()
                        trailing
                    }
                    words
                }
            } else {
                HStack(spacing: 12) {
                    if showsAvatar { TaskAvatar(item: item) }
                    words.frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityValue)
        // Combining the row hides the tick circle from VoiceOver; offer it as an action.
        .accessibilityActions {
            if let tick { Button(tick.label, action: tick.run) }
        }
    }

    /// What the tick circle does on this row, if it has one.
    private var tick: (label: String, run: () -> Void)? {
        switch item {
        case .own(let task):
            return (task.isDone ? "Mark not done" : "Mark done", { model.setDone(task.id, !task.isDone) })
        case .steward(let task):
            return TaskStatus(of: task) == .yours ? ("Mark done", { model.markTaskDone(task.id) }) : nil
        case .errand(let file):
            return TaskStatus(of: file) == .yours ? ("Mark done", { model.markDone(file.id) }) : nil
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(isFinished ? Palette.muted : Palette.ink)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            subtitle
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var subtitle: some View {
        if model.working.contains(item.id) {
            Label { Text("Steward is on it…") } icon: { ProgressView().controlSize(.mini) }
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
        } else if let problem = model.problems[item.id] {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Palette.orangeText)
                .lineLimit(2)
        } else if !line.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if case .errand(let file) = item {
                    Image(systemName: ErrandKind(of: file).symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isFinished ? Palette.muted : ErrandKind(of: file).deep)
                        .accessibilityHidden(true)
                }
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(lineColor)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item {
        case .own(let task):
            CheckCircle(done: task.isDone) { model.setDone(task.id, !task.isDone) }
        case .steward(let task):
            switch TaskStatus(of: task) {
            case .yours: CheckCircle(done: false) { model.markTaskDone(task.id) }
            case .done: FinishedMark(done: true)
            case .stopped: FinishedMark(done: false)
            case .needsYou, .onIt: EmptyView()
            }
        case .errand(let file):
            switch TaskStatus(of: file) {
            case .yours: CheckCircle(done: false) { model.markDone(file.id) }
            case .done: FinishedMark(done: true)
            case .stopped: FinishedMark(done: false)
            case .needsYou, .onIt: EmptyView()
            }
        }
    }

    private var line: String {
        switch item {
        case .own(let task): task.statusLine
        case .steward(let task): task.statusLine(connected: model.canWork)
        case .errand(let file): file.statusLine
        }
    }

    private var isFinished: Bool {
        switch item {
        case .own(let task): task.isDone
        case .steward(let task): task.isFinished
        case .errand(let file): [.done, .stopped].contains(TaskStatus(of: file))
        }
    }

    private var lineColor: Color {
        switch item {
        case .own(let task): return task.isOverdue ? Palette.orangeText : Palette.muted
        case .steward(let task):
            return task.isOverdue || TaskStatus(of: task) == .needsYou ? Palette.orangeText : Palette.muted
        case .errand(let file):
            if file.isOverdue || TaskStatus(of: file) == .needsYou { return Palette.orangeText }
            return Palette.muted
        }
    }

    private var accessibilityValue: String {
        let who: String
        switch item {
        case .own(let task): who = task.isDone ? "Your task, done" : "Your task"
        case .steward(let task): who = "Steward's task, \(TaskStatus(of: task).accessibilityLabel)"
        case .errand(let file): who = "Steward's errand, \(TaskStatus(of: file).accessibilityLabel)"
        }
        return line.isEmpty ? who : "\(who). \(line)"
    }
}

/// Whose move it is. You: your photo or initials. Steward: the cat. Steward
/// asking you something: the cat in an orange ring. Handed back to you: you,
/// with a small cat for whose errand it was.
struct TaskAvatar: View {
    let item: TaskItem
    var size: CGFloat = 36

    @Environment(TasksModel.self) private var model

    var body: some View {
        ZStack {
            switch item {
            case .own(let task):
                OwnerAvatar(size: size).opacity(task.isDone ? 0.5 : 1)
            case .steward(let task):
                face(TaskStatus(of: task), turning: model.canWork && !task.isOverdue)
            case .errand(let file):
                face(TaskStatus(of: file), turning: model.canAct && !file.isOverdue)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func face(_ status: TaskStatus, turning: Bool) -> some View {
        switch status {
        case .needsYou:
            StewardAvatar(size: size, blinks: false, neutral: true)
                .background { Circle().strokeBorder(Palette.orange, lineWidth: 2).padding(-4) }
        case .yours:
            OwnerAvatar(size: size)
                .overlay(alignment: .bottomTrailing) { catBadge }
        case .onIt:
            StewardAvatar(size: size, blinks: false, neutral: true)
                .background { WorkingRing(turning: turning).padding(-4) }
        case .done, .stopped:
            StewardAvatar(size: size, blinks: false, neutral: true).opacity(0.45)
        }
    }

    private var catBadge: some View {
        StewardAvatar(size: size * 0.46, blinks: false, neutral: true)
            .padding(1.5)
            .background(Palette.row, in: .circle)
            .offset(x: 4, y: 4)
    }
}

/// The dashed ring around Steward while it works. It turns slowly while
/// Steward can act, and holds still when it can't.
private struct WorkingRing: View {
    let turning: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0

    var body: some View {
        Circle()
            .inset(by: 1)
            .stroke(Palette.muted, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4.4]))
            .rotationEffect(.degrees(angle))
            .task(id: turning && !reduceMotion) {
                guard turning, !reduceMotion else { angle = 0; return }
                withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

/// The circle that ticks a task off. 44pt to tap, drawn smaller.
private struct CheckCircle: View {
    let done: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                if done {
                    Circle().fill(Palette.muted)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Palette.row)
                } else {
                    Circle().strokeBorder(Palette.muted, lineWidth: 1.75)
                }
            }
            .frame(width: 24, height: 24)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .sensoryFeedback(.success, trigger: done) { _, new in new }
        .accessibilityLabel(done ? "Mark not done" : "Mark done")
    }
}

/// How a finished errand ended, small and quiet.
private struct FinishedMark: View {
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "xmark.circle")
            .font(.title3)
            .foregroundStyle(Palette.muted)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

// MARK: Actions

/// Swipes and the long-press menu: the same moves, in both places.
private struct TaskActions: ViewModifier {
    let item: TaskItem
    let handToSteward: (OwnerTask) -> Void

    @Environment(TasksModel.self) private var model

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) { leading }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailing }
            .contextMenu { menu }
    }

    @ViewBuilder
    private var leading: some View {
        switch item {
        case .own(let task):
            Button(task.isDone ? "Not Done" : "Done", systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark") {
                model.setDone(task.id, !task.isDone)
            }
            .tint(task.isDone ? .gray : .green)
        case .steward(let task):
            switch TaskStatus(of: task) {
            case .onIt where task.isOverdue && model.canWork:
                Button("Check Back", systemImage: "arrow.clockwise") { model.checkBack(task.id) }.tint(.blue)
            case .yours, .onIt, .needsYou:
                Button("Done", systemImage: "checkmark") { model.markTaskDone(task.id) }.tint(.green)
            default:
                EmptyView()
            }
        case .errand(let file):
            switch TaskStatus(of: file) {
            case .onIt where file.isOverdue && model.canAct:
                Button("Follow Up", systemImage: "arrow.clockwise") { model.nudge(file.id) }.tint(.blue)
            case .yours, .onIt:
                Button("Done", systemImage: "checkmark") { model.markDone(file.id) }.tint(.green)
            case .done where !file.isConfirmedByOwner:
                Button("Confirm", systemImage: "checkmark.seal") { model.markDone(file.id) }.tint(.green)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item {
        case .own(let task):
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(task.id) }
            if !task.isDone {
                Button("Steward", systemImage: "arrow.right.circle") { handToSteward(task) }.tint(Palette.ink)
            }
        case .steward(let task):
            if task.isFinished {
                Button("Delete", systemImage: "trash", role: .destructive) { model.deleteStewardTask(task.id) }
            } else {
                Button("Stop", systemImage: "stop.circle", role: .destructive) { model.stopTask(task.id) }
                if TaskStatus(of: task) != .yours {
                    Button("Take Over", systemImage: "hand.raised") { model.takeOverTask(task.id) }.tint(.indigo)
                }
            }
        case .errand(let file):
            if [.needsYou, .onIt].contains(TaskStatus(of: file)) {
                Button("Stop", systemImage: "stop.circle", role: .destructive) { model.stop(file.id) }
                Button("Take Over", systemImage: "hand.raised") { model.takeOver(file.id) }.tint(.indigo)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch item {
        case .own(let task):
            Button(task.isDone ? "Mark Not Done" : "Mark Done", systemImage: task.isDone ? "circle" : "checkmark.circle") {
                model.setDone(task.id, !task.isDone)
            }
            if !task.isDone {
                Button("Hand to Steward", systemImage: "arrow.right.circle") { handToSteward(task) }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(task.id) }
        case .steward(let task):
            StewardTaskMenu(task: task)
        case .errand(let file):
            let status = TaskStatus(of: file)
            if status == .onIt, file.isOverdue, model.canAct {
                Button("Follow Up Now", systemImage: "arrow.clockwise") { model.nudge(file.id) }
            }
            if [.needsYou, .onIt, .yours].contains(status) {
                Button("Mark Done", systemImage: "checkmark.circle") { model.markDone(file.id) }
            }
            if status == .done, !file.isConfirmedByOwner {
                Button("Confirm It's Sorted", systemImage: "checkmark.seal") { model.markDone(file.id) }
            }
            if [.needsYou, .onIt].contains(status) {
                Button("Take Over", systemImage: "hand.raised") { model.takeOver(file.id) }
                Divider()
                Button("Stop Errand", systemImage: "stop.circle", role: .destructive) { model.stop(file.id) }
            }
        }
    }
}

/// The last move, with a way back, for a few seconds.
struct UndoToast: View {
    @Environment(TasksModel.self) private var model

    var body: some View {
        if let undo = model.undo {
            HStack(spacing: 16) {
                Text(undo.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                Button("Undo") { withAnimation(.snappy) { model.performUndo() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.orangeText)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.id) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.snappy) { model.dismissUndo(undo.id) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Undo") { model.performUndo() }
        }
    }
}

// MARK: Empty

/// First run: nothing yet. Two ways in, and three errands to start from.
private struct EmptyTasks: View {
    let add: (AddRequest) -> Void

    /// A spread of what Steward can take on, so it doesn't read as one trick.
    private let starters: [(String, String, String)] = [
        ("Cancel a subscription", "scissors", "Cancel my "),
        ("Plan a weekend away", "map", "Plan a weekend in "),
        ("Compare prices", "chart.bar.xaxis", "Find the best price for "),
        ("Remind me before a deadline", "calendar.badge.clock", "Remind me before "),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    HStack(spacing: -10) {
                        OwnerAvatar(size: 56)
                            .overlay(Circle().stroke(Palette.ground, lineWidth: 3))
                        StewardAvatar(size: 56, blinks: true)
                            .overlay(Circle().stroke(Palette.ground, lineWidth: 3))
                    }
                    Text("Nothing on your list")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Palette.ink)
                    Text("Add something to do yourself, or hand anything to Steward. Both live here until they're done.")
                        .font(.body)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    Button { add(AddRequest()) } label: {
                        Text("Add a Task").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.orange)
                    .foregroundStyle(Palette.onOrange)
                    Button { add(AddRequest(doer: .steward)) } label: {
                        Text("Ask Steward").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.ink)
                }
                .controlSize(.large)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Steward can start with")
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    VStack(spacing: 0) {
                        ForEach(starters, id: \.0) { title, symbol, prompt in
                            Button { add(AddRequest(text: prompt, doer: .steward)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: symbol)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Palette.muted)
                                        .frame(width: 28)
                                    Text(title).foregroundStyle(Palette.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Palette.muted)
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 50)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            if title != starters.last?.0 { Divider().padding(.leading, 56) }
                        }
                    }
                    .background(Palette.row, in: .rect(cornerRadius: Palette.cardRadius))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }
}

struct KindTile: View {
    let kind: ErrandKind
    var size: CGFloat = 44

    /// Grows with the glyph so the icon never spills out of its tile.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = size * min(max(scale, 1), 1.6)
        Image(systemName: kind.symbol)
            .font(.body.weight(.semibold))
            .imageScale(scale > 1.6 ? .small : .medium)
            .foregroundStyle(kind.deep)
            .frame(width: side, height: side)
            .background(kind.tile, in: .rect(cornerRadius: side * 0.28))
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
    @State private var turning = false

    var body: some View {
        ZStack {
            switch status {
            case .needsYou:
                Circle().strokeBorder(Palette.orange, lineWidth: 2.5)
                Circle().fill(Palette.orange).frame(width: size * 0.32, height: size * 0.32)
            case .onIt:
                // One repeating animation instead of a redraw every frame.
                dashedRing
                    .rotationEffect(.degrees(turning ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { turning = true }
                    }
                    .onChange(of: reduceMotion) {
                        if reduceMotion { withAnimation(nil) { turning = false } }
                    }
            case .yours:
                Circle().strokeBorder(Palette.ink, lineWidth: 2)
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

    /// The icon tile.
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
