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
