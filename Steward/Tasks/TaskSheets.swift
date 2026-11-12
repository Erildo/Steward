import SwiftUI
import StewardCore

/// What the add sheet opens with: empty, or started from a suggestion.
struct AddRequest: Identifiable {
    let id = UUID()
    var text = ""
    var doer = AddTaskSheet.Doer.me
}

/// Adds a task: what it is, who does it, and for your own a date if it has one.
/// A task for Steward lands in the list at once and Steward starts on it.
struct AddTaskSheet: View {
    let request: AddRequest
    /// Opens a task that already exists, when the owner picks it over a duplicate.
    let open: (UUID) -> Void

    enum Doer: Hashable { case me, steward }

    @Environment(TasksModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var doer: Doer

    init(request: AddRequest, open: @escaping (UUID) -> Void) {
        self.request = request
        self.open = open
        _title = State(initialValue: request.text)
        _doer = State(initialValue: request.doer)
    }

    @State private var hasDue = false
    @State private var due = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var duplicate: TaskItem?
    @FocusState private var focused: Bool

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(doer == .me ? "What needs doing?" : "What should Steward do?", text: $title, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...4)
                        .submitLabel(.done)
                        .onSubmit(submit)
                }
                Section {
                    Picker("Who does it", selection: $doer) {
                        Text("Me").tag(Doer.me)
                        Text("Steward").tag(Doer.steward)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if doer == .me {
                    Section {
                        Toggle("Due date", isOn: $hasDue.animation())
                        if hasDue {
                            DatePicker("Due", selection: $due, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .tint(Palette.orange)
                        }
                    }
                } else {
                    Section {
                    } footer: {
                        Text(model.canWork
                             ? "Steward starts right away and asks here if it needs anything. Nothing goes out without your OK."
                             : "It waits in your list until Steward is connected.")
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
            .alert("You already have this", isPresented: .init(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }), presenting: duplicate) { item in
                Button("Open It") {
                    dismiss()
                    open(item.id)
                }
                Button("Add Anyway") { commit() }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("“\(item.title)” is still open.")
            }
        }
        .presentationDetents(doer == .me && hasDue ? [.large] : [.medium, .large])
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        if let existing = model.existing(named: trimmed) {
            duplicate = existing
        } else {
            commit()
        }
    }

    private func commit() {
        switch doer {
        case .me:
            model.add(trimmed, due: hasDue ? due : nil)
        case .steward:
            model.addStewardTask(trimmed)
        }
        dismiss()
    }
}

/// One of your own tasks, to rename, note, date, finish, hand over or delete.
struct OwnerTaskDetail: View {
    let id: UUID

    @Environment(TasksModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OwnerTask?

    var body: some View {
        Group {
            if let task = model.task(id) {
                form(task)
            } else {
                ContentUnavailableView("Task deleted", systemImage: "trash", description: Text("Undo from the list to bring it back."))
            }
        }
        .background(Palette.ground)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ task: OwnerTask) -> some View {
        let binding = Binding<OwnerTask>(
            get: { draft ?? task },
            set: { draft = $0 }
        )
        return Form {
            Section {
                TextField("Task", text: binding.title, axis: .vertical)
                    .font(.title3.weight(.semibold))
                TextField("Note", text: binding.note, axis: .vertical)
                    .lineLimit(2...8)
            }
            Section {
                Toggle("Due date", isOn: Binding(
                    get: { binding.wrappedValue.due != nil },
                    set: { binding.wrappedValue.due = $0 ? (binding.wrappedValue.due ?? .now) : nil }
                ).animation())
                if let due = binding.wrappedValue.due {
                    DatePicker("Due", selection: Binding(get: { due }, set: { binding.wrappedValue.due = $0 }), displayedComponents: .date)
                        .tint(Palette.orange)
                }
            }
            Section {
                Button(task.isDone ? "Mark Not Done" : "Mark Done", systemImage: task.isDone ? "circle" : "checkmark.circle") {
                    save()
                    model.setDone(id, !task.isDone)
                    draft = nil
                }
                if !task.isDone {
                    Button("Hand to Steward", systemImage: "arrow.right.circle") {
                        save()
                        model.handToSteward(id)
                        dismiss()
                    }
                }
            } footer: {
                if !task.isDone {
                    Text("It moves to Steward's tasks, and Steward starts on it.")
                }
            }
            Section {
                Button("Delete Task", systemImage: "trash", role: .destructive) {
                    model.delete(id)
                    dismiss()
                }
            }
        }
        .tint(Palette.ink)
        .scrollContentBackground(.hidden)
        .onDisappear(perform: save)
    }

    private func save() {
        guard var draft else { return }
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.title.isEmpty, let task = model.task(id) { draft.title = task.title }
        model.update(draft)
        self.draft = nil
    }
}

/// Tasks finished more than 30 days ago.
struct ArchiveView: View {
    let scope: TaskScope

    @Environment(TasksModel.self) private var model

    private var archived: [TaskItem] { model.archived.filter(scope.contains) }

    var body: some View {
        Group {
            if archived.isEmpty {
                ContentUnavailableView("Nothing archived", systemImage: "archivebox",
                                       description: Text("Done tasks move here after 30 days."))
            } else {
                List {
                    ForEach(archived) { item in
                        NavigationLink(value: item.id) { TaskRow(item: item) }
                            .swipeActions {
                                if case .own(let task) = item {
                                    Button("Delete", systemImage: "trash", role: .destructive) { model.delete(task.id) }
                                }
                            }
                    }
                    .listRowBackground(Palette.row)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.ground)
        .navigationTitle("Archive")
    }
}

/// The owner's moves on a Steward task, for its menu and long-press.
struct StewardTaskMenu: View {
    let task: StewardTask

    @Environment(TasksModel.self) private var model

    var body: some View {
        let status = TaskStatus(of: task)
        if status == .onIt, task.isOverdue, model.canWork {
            Button("Check Back Now", systemImage: "arrow.clockwise") { model.checkBack(task.id) }
        }
        if !task.isFinished {
            Button("Mark Done", systemImage: "checkmark.circle") { model.markTaskDone(task.id) }
        }
        if case .done(_, false) = task.state {
            Button("Confirm It's Sorted", systemImage: "checkmark.seal") { model.markTaskDone(task.id) }
        }
        if [.needsYou, .onIt].contains(status) {
            Button("Take Over", systemImage: "hand.raised") { model.takeOverTask(task.id) }
        }
        Divider()
        if task.isFinished {
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteStewardTask(task.id) }
        } else {
            Button("Stop Task", systemImage: "stop.circle", role: .destructive) { model.stopTask(task.id) }
        }
    }
}

/// One Steward task: where it stands, the result when there is one, and its
/// own conversation, with a composer to answer or add to it.
struct StewardTaskDetail: View {
    let id: UUID

    @Environment(TasksModel.self) private var model
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        if let task = model.stewardTask(id) {
            content(task)
        } else {
            ContentUnavailableView("Task deleted", systemImage: "trash", description: Text("Undo from the list to bring it back."))
        }
    }

    private func content(_ task: StewardTask) -> some View {
        let status = TaskStatus(of: task)
        let busy = model.working.contains(id)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.goal)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Palette.ink)
                        Text("Given to Steward \(task.createdAt.taskDay)")
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                    }
                    statusCard(task, status: status)
                    if let result = task.result, case .done = task.state {
                        resultCard(task, result)
                    }
                    if let file = task.caseID.flatMap(model.file) {
                        NavigationLink(value: file.id) {
                            Label("Company case: \(file.title)", systemImage: "envelope")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conversation")
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(task.messages) { message in
                            Bubble(message: message)
                        }
                        if busy {
                            HStack(spacing: 8) {
                                StewardAvatar(size: 24, neutral: true)
                                ProgressView().controlSize(.small)
                                Text("Steward is working…").font(.footnote).foregroundStyle(Palette.muted)
                            }
                            .padding(.top, 4)
                        }
                        if let problem = model.problems[id] {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Palette.ink)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: task.messages.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: busy) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Palette.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { StewardTaskMenu(task: task) } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Task actions")
            }
        }
        .safeAreaInset(edge: .bottom) { composer(task, busy: busy) }
    }

    private func statusCard(_ task: StewardTask, status: TaskStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatusCircle(status: status, tint: Palette.muted, size: 24).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(status.accessibilityLabel).font(.headline).foregroundStyle(Palette.ink)
                Text(task.statusLine(connected: model.canWork))
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.row, in: .rect(cornerRadius: Palette.cardRadius))
        .overlay {
            if status == .needsYou {
                RoundedRectangle(cornerRadius: Palette.cardRadius + 3)
                    .strokeBorder(Palette.orange, lineWidth: 1.5)
                    .padding(-3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func resultCard(_ task: StewardTask, _ result: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Result").font(.headline).foregroundStyle(Palette.ink)
            Text(result)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
            HStack {
                ShareLink(item: result) { Label("Share", systemImage: "square.and.arrow.up") }
                Spacer()
                if case .done(_, false) = task.state {
                    Button("Confirm It's Sorted", systemImage: "checkmark.seal") { model.markTaskDone(task.id) }
                }
            }
            .font(.subheadline.weight(.semibold))
            .tint(Palette.ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.row, in: .rect(cornerRadius: Palette.cardRadius))
    }

    private func composer(_ task: StewardTask, busy: Bool) -> some View {
        let canSend = model.canWork && !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let placeholder: String = {
            if !model.canWork { return "Steward isn't connected yet" }
            if case .needsAnswer = task.state { return "Answer Steward" }
            return "Write to Steward about this"
        }()
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composing)
                .tint(Palette.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .disabled(!model.canWork)
            Button {
                model.send(id, draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Palette.onOrange)
                    .frame(width: 34, height: 34)
                    .background(Palette.orange, in: .circle)
            }
            .frame(minWidth: 44, minHeight: 44)
            .opacity(canSend ? 1 : 0.35)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.trailing, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// One message in a task's thread: yours on the right, Steward's on the left.
private struct Bubble: View {
    let message: StewardTask.Message

    var body: some View {
        let mine = message.author == .owner
        HStack {
            if mine { Spacer(minLength: 48) }
            Text(message.text)
                .font(.body)
                .foregroundStyle(mine ? Palette.onOrange : Palette.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(mine ? Palette.orange : Palette.stewardBubble, in: .rect(cornerRadius: Palette.bubbleRadius))
            if !mine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "You" : "Steward"): \(message.text)")
    }
}
