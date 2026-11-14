import SwiftUI
import StewardCore

/// The owner's Steward: what it can reach, what it holds, what it knows, the
/// rules it keeps, and the app's own settings. Nothing about Steward is kept
/// somewhere the owner can't see or change.
struct StewardTabView: View {
    @Environment(StewardTabModel.self) private var model
    @Environment(InsightsModel.self) private var insights
    @Environment(TasksModel.self) private var tasks
    @Environment(OwnerProfile.self) private var profile

    @State private var showsProfile = false
    @State private var showsConnect = false
    @State private var showsKnown = false
    @State private var confirmsDelete = false
    @State private var export: ExportBundle?

    @AppStorage(Appearance.storageKey, store: Appearance.store) private var appearance = Appearance.light
    @AppStorage(StewardRules.spendLimitKey) private var spendLimit = 0.0
    @AppStorage(StewardRules.quietKey) private var quietHours = false
    @AppStorage(StewardRules.quietFromKey) private var quietFrom = StewardRules.defaultFrom
    @AppStorage(StewardRules.quietToKey) private var quietTo = StewardRules.defaultTo
    @AppStorage(AppLock.storageKey) private var locks = false
    @State private var lockProblem: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                List {
                    owner(scroller)
                    appsSection.id(Anchor.apps)
                    filesSection.id(Anchor.files)
                    knownSection
                    rulesSection
                    aiSection
                    appSection
                    dataSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .background(Palette.ground)
            .navigationTitle("Steward")
            .navigationDestination(for: ConnectedAppRoute.self) { route in
                ConnectedAppDetail(id: route.id)
            }
            .navigationDestination(for: StewardFile.Origin.self) { origin in
                FilesView(origin: origin)
            }
            .tint(Palette.ink)
        }
        .sheet(isPresented: $showsProfile) { ProfileSheet() }
        .sheet(isPresented: $showsConnect) { ConnectAppSheet() }
        .sheet(isPresented: $showsKnown) { KnownView().environment(insights) }
        .sheet(item: $export) { bundle in ShareSheet(items: bundle.urls) }
        .alert("Face ID isn't available", isPresented: Binding(get: { lockProblem != nil }, set: { if !$0 { lockProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lockProblem ?? "")
        }
    }

    private enum Anchor: Hashable { case apps, files }

    // MARK: You

    private func owner(_ scroller: ScrollViewProxy) -> some View {
        Section {
            Button { showsProfile = true } label: {
                HStack(spacing: 14) {
                    OwnerAvatar(size: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name.isEmpty ? "Add your name" : profile.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Text("Photo and name")
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(Palette.row)
        } header: {
            if model.isSample {
                Text("Sample: nothing here is real.")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                    .textCase(nil)
            }
        } footer: {
            HStack(spacing: 4) {
                Text("Reaches")
                Button(count(reachable, "app")) { withAnimation { scroller.scrollTo(Anchor.apps, anchor: .top) } }
                Text("·")
                Text("holds")
                Button(count(model.files.count, "file")) { withAnimation { scroller.scrollTo(Anchor.files, anchor: .top) } }
            }
            .font(.footnote)
            .foregroundStyle(Palette.muted)
            .buttonStyle(.borderless)
            .tint(Palette.orangeText)
        }
    }

    private var reachable: Int { model.apps.filter { !$0.needsSignIn }.count }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: Apps

    private var appsSection: some View {
        Section {
            ForEach(model.apps) { app in
                NavigationLink(value: ConnectedAppRoute(id: app.id)) {
                    AppRow(app: app)
                }
                .listRowBackground(Palette.row)
            }
            Button { showsConnect = true } label: {
                Label {
                    Text("Connect an App").foregroundStyle(Palette.orangeText)
                } icon: {
                    AppIcon(systemImage: "plus", color: Palette.orange, glyph: Palette.onOrange)
                }
            }
            .listRowBackground(Palette.row)
        } header: {
            header("Connected apps")
        } footer: {
            Text(model.apps.isEmpty
                 ? "Connect your mail, calendar or a website and Steward can find bills, book times and reply for you. Nothing is sent without your yes."
                 : "Websites connect when you sign in through Steward. It never sees your password.")
        }
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            ForEach(StewardFile.Origin.allCases) { origin in
                NavigationLink(value: origin) {
                    LabeledContent {
                        Text("\(model.files(origin).count)").monospacedDigit()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(origin.title).foregroundStyle(Palette.ink)
                                Text(origin == .steward ? "Letters, forms and proof" : "Bills, receipts and contracts")
                                    .font(.footnote)
                                    .foregroundStyle(Palette.muted)
                            }
                        } icon: {
                            if origin == .steward {
                                StewardAvatar(size: 29, blinks: false)
                            } else {
                                AppIcon(systemImage: "doc", color: Color(.systemGray), glyph: .white)
                            }
                        }
                    }
                }
                .listRowBackground(Palette.row)
            }
        } header: {
            header("Files")
        } footer: {
            Text("Each file is kept with the task it belongs to.")
        }
    }

    // MARK: Memory

    private var knownSection: some View {
        Section {
            Button { showsKnown = true } label: {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text("\(insights.known.count)").monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                } label: {
                    Label("What Steward Knows", systemImage: "person.text.rectangle")
                        .foregroundStyle(Palette.ink)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(Palette.row)
        } header: {
            header("Memory")
        } footer: {
            Text("What you told Steward and what it guessed, each with where it came from. Forget anything, any time.")
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            ForEach(StewardRules.alwaysAsks, id: \.title) { rule in
                LabeledContent {
                    Text("Always asks")
                } label: {
                    Label(rule.title, systemImage: rule.systemImage)
                        .foregroundStyle(Palette.ink)
                }
                .listRowBackground(Palette.row)
                .accessibilityHint("Can't be turned off")
            }
            LabeledContent {
                TextField("No limit", value: limitBinding,
                          format: .currency(code: StewardRules.currency).precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 140)
            } label: {
                Label("Payment Limit", systemImage: "creditcard")
                    .foregroundStyle(Palette.ink)
            }
            .listRowBackground(Palette.row)
            Toggle(isOn: $quietHours.animation()) {
                Label("Quiet Hours", systemImage: "moon")
                    .foregroundStyle(Palette.ink)
            }
            .tint(Palette.orange)
            .listRowBackground(Palette.row)
            if quietHours {
                DatePicker("From", selection: timeBinding($quietFrom), displayedComponents: .hourAndMinute)
                    .listRowBackground(Palette.row)
                DatePicker("Until", selection: timeBinding($quietTo), displayedComponents: .hourAndMinute)
                    .listRowBackground(Palette.row)
            }
        } header: {
            header("Ask me first")
        } footer: {
            Text(quietHours
                 ? "Payments, messages and account changes always wait for your yes. In quiet hours Steward keeps working but holds its questions until morning."
                 : "Payments, messages and account changes always wait for your yes. A payment above your limit, Steward hands back for you to make yourself.")
        }
    }

    private var limitBinding: Binding<Double?> {
        Binding(get: { spendLimit > 0 ? spendLimit : nil }, set: { spendLimit = max($0 ?? 0, 0) })
    }

    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(Double(minutes.wrappedValue) * 60) },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    // MARK: AI

    private var aiSection: some View {
        Section {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Steward's AI").foregroundStyle(Palette.ink)
                        Text("Picks a model for each job. Nothing to set up.")
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.orangeText)
                    .accessibilityLabel("In use")
            }
            .listRowBackground(Palette.row)
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Own AI Key")
                    Text("Coming later, when Steward opens up. Never required.")
                        .font(.footnote)
                }
            } icon: {
                Image(systemName: "key")
            }
            .foregroundStyle(Palette.muted)
            .listRowBackground(Palette.row)
            .accessibilityHint("Not available yet")
        } header: {
            header("AI")
        }
    }

    // MARK: App

    private var appSection: some View {
        Section {
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
                    .foregroundStyle(Palette.ink)
            }
            .listRowBackground(Palette.row)
            Button {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                } label: {
                    Label("Notifications", systemImage: "bell")
                        .foregroundStyle(Palette.ink)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .listRowBackground(Palette.row)
            .accessibilityHint("Opens Settings")
            Toggle(isOn: lockBinding) {
                Label("Lock with \(AppLock.biometryName)", systemImage: AppLock.systemImage)
                    .foregroundStyle(Palette.ink)
            }
            .tint(Palette.orange)
            .listRowBackground(Palette.row)
        } header: {
            header("App")
        } footer: {
            Text("When locked, Steward asks for \(AppLock.biometryName) each time you come back to it.")
        }
    }

    /// Turning the lock on checks it works first, so nobody locks themselves out.
    private var lockBinding: Binding<Bool> {
        Binding(get: { locks }, set: { on in
            guard on else { locks = false; return }
            Task {
                switch await AppLock.authenticate(reason: "Lock Steward with \(AppLock.biometryName)") {
                case .success: locks = true
                case .unavailable(let why): lockProblem = why
                case .cancelled: break
                }
            }
        })
    }

    // MARK: Your data

    private var dataSection: some View {
        Section {
            Button {
                export = ExportBundle.make(insights: insights, tasks: tasks, files: model.files)
            } label: {
                Label("Export Everything", systemImage: "square.and.arrow.up")
                    .foregroundStyle(Palette.ink)
            }
            .listRowBackground(Palette.row)
            Button(role: .destructive) { confirmsDelete = true } label: {
                Label("Delete Everything", systemImage: "trash")
            }
            .listRowBackground(Palette.row)
            .confirmationDialog("Delete everything Steward holds?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { deleteEverything() }
            } message: {
                Text("Your files, connections, memory and tasks are removed from this iPhone. This can't be undone. Errands still open with a company close on their own.")
            }
        } header: {
            header("Your data")
        } footer: {
            Text("Export gives you your memory, your tasks and every file, in formats any computer can open.")
        }
    }

    private func deleteEverything() {
        model.removeEverything()
        for item in insights.known { insights.forget(item) }
        for task in tasks.ownTasks { tasks.delete(task.id) }
        for task in tasks.stewardTasks { tasks.deleteStewardTask(task.id) }
        profile.name = ""
        profile.setPhoto(nil)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .textCase(nil)
            .padding(.leading, -4)
    }
}

/// Opens one connected app's detail. A route type of its own, so it can't
/// collide with other string destinations.
struct ConnectedAppRoute: Hashable { let id: String }

// MARK: Rows

/// A Settings-style icon: a white glyph on a small rounded square.
struct AppIcon: View {
    let systemImage: String
    let color: Color
    var glyph: Color = .white
    var size: CGFloat = 29

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = size * scale

        Image(systemName: systemImage)
            .font(.system(size: side * 0.52, weight: .medium))
            .foregroundStyle(glyph)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.24))
            .accessibilityHidden(true)
    }
}

struct AppRow: View {
    let app: ConnectedApp

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if app.needsSignIn {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                        Text("Sign-in ran out")
                    }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Palette.orangeText)
                } else {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                }
            }
        } icon: {
            AppIcon(systemImage: app.systemImage, color: app.color)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        guard let used = app.lastUsed else { return app.summary }
        return "\(app.summary) · used \(used.formatted(.relative(presentation: .named)))"
    }
}

// MARK: Rules

enum StewardRules {
    struct Rule { let title: String; let systemImage: String }

    /// Never a switch: the product promises these wait for a yes.
    static let alwaysAsks = [
        Rule(title: "Payments", systemImage: "banknote"),
        Rule(title: "Messages", systemImage: "paperplane"),
        Rule(title: "Account Changes", systemImage: "person.badge.key"),
    ]

    static let spendLimitKey = "rules.spendLimit"
    static let quietKey = "rules.quietHours"
    static let quietFromKey = "rules.quietFrom"
    static let quietToKey = "rules.quietTo"
    /// Minutes after midnight.
    static let defaultFrom = 22 * 60
    static let defaultTo = 8 * 60

    static var currency: String { Locale.current.currency?.identifier ?? "EUR" }
}

// MARK: Export

/// Everything the owner holds, written out as plain files to share or save.
struct ExportBundle: Identifiable {
    let id = UUID()
    let urls: [URL]

    @MainActor static func make(insights: InsightsModel, tasks: TasksModel, files: [StewardFile]) -> ExportBundle {
        let folder = URL.temporaryDirectory.appending(path: "Steward export", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let memory = folder.appending(path: "What Steward knows.txt")
        try? insights.exportText.write(to: memory, atomically: true, encoding: .utf8)

        var lines = ["Your tasks", ""]
        lines += tasks.ownTasks.map { "- \($0.title)\($0.doneAt == nil ? "" : " (done)")" }
        lines += ["", "Handed to Steward", ""]
        lines += tasks.stewardTasks.map { "- \($0.goal)" }
        lines += tasks.cases.map { "- \($0.title)" }
        let list = folder.appending(path: "Tasks.txt")
        try? lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)

        return ExportBundle(urls: [memory, list] + files.map(\.url))
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
