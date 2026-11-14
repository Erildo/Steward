import SwiftUI
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Every file Steward holds, one side at a time: what Steward made for the
/// owner's tasks, and what the owner gave it. Grouped by the task each belongs to.
struct FilesView: View {
    @State var origin: StewardFile.Origin

    @Environment(StewardTabModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var query = ""
    @State private var previewing: URL?
    @State private var adding = false
    @State private var removed: StewardFile?
    @State private var addProblem: String?

    var body: some View {
        List {
            Section {
                Picker("Files", selection: $origin) {
                    ForEach(StewardFile.Origin.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if shown.isEmpty {
                Section {
                    empty.listRowBackground(Color.clear)
                }
            }

            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.files) { file in
                        row(file)
                    }
                } header: {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.muted)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add a File", systemImage: "plus") { adding = true }
            }
        }
        .quickLookPreview($previewing, in: shown.map(\.url))
        .fileImporter(isPresented: $adding, allowedContentTypes: [.pdf, .image, .plainText, .rtf], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { try model.add(url) }
                origin = .owner
            } catch {
                addProblem = "Steward couldn't copy that file. Try saving it to Files first, then add it from there."
            }
        }
        .alert("File not added", isPresented: Binding(get: { addProblem != nil }, set: { if !$0 { addProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addProblem ?? "")
        }
        .overlay(alignment: .bottom) { undoBar }
        .animation(.default, value: model.files)
    }

    private var shown: [StewardFile] {
        let files = model.files(origin)
        guard !query.isEmpty else { return files }
        return files.filter {
            $0.name.localizedStandardContains(query) || ($0.taskTitle?.localizedStandardContains(query) ?? false)
                || $0.kind.localizedStandardContains(query)
        }
    }

    /// By task, newest task first; files with no task go last.
    private var groups: [(title: String, files: [StewardFile])] {
        var order: [String] = []
        var byTask: [String: [StewardFile]] = [:]
        for file in shown {
            let key = file.taskTitle ?? "Not part of a task"
            if byTask[key] == nil { order.append(key) }
            byTask[key, default: []].append(file)
        }
        order.sort { a, b in
            if a == "Not part of a task" { return false }
            if b == "Not part of a task" { return true }
            return (byTask[a]?.first?.date ?? .distantPast) > (byTask[b]?.first?.date ?? .distantPast)
        }
        return order.map { ($0, byTask[$0] ?? []) }
    }

    private func row(_ file: StewardFile) -> some View {
        Button { previewing = file.url } label: {
            HStack(spacing: 12) {
                FileThumbnail(url: file.url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    Text("\(file.kind) · \(file.date.formatted(.relative(presentation: .named)))")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.row)
        .accessibilityHint("Opens a preview")
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(file) }
        }
        .contextMenu {
            ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
            if let id = file.taskID {
                Button("Open Task", systemImage: "checkmark.square") { router.openTask(id) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(file) }
        } preview: {
            FileThumbnail(url: file.url, side: 260)
        }
    }

    private func delete(_ file: StewardFile) {
        if let earlier = removed { model.purge(earlier) }
        model.remove(file)
        removed = file
    }

    @ViewBuilder
    private var undoBar: some View {
        if let file = removed {
            HStack {
                Text("“\(file.name)” deleted")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") {
                    model.restore(file)
                    removed = nil
                }
                .font(.subheadline.weight(.semibold))
                .tint(Palette.orangeText)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: file) {
                try? await Task.sleep(for: .seconds(5))
                model.purge(file)
                if removed == file { removed = nil }
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if origin == .steward {
            ContentUnavailableView("Nothing made yet", systemImage: "doc.text",
                                   description: Text("Letters, filled-in forms and proof that an errand worked appear here, each with its task."))
        } else {
            ContentUnavailableView {
                Label("Nothing from you yet", systemImage: "tray")
            } description: {
                Text("Bills, receipts and contracts you send in a chat land here. You can add one now too.")
            } actions: {
                Button("Add a File") { adding = true }
                    .buttonStyle(.bordered)
                    .tint(Palette.orangeText)
            }
        }
    }
}

/// The first page of a file, as the system draws it.
struct FileThumbnail: View {
    let url: URL
    var side: CGFloat = 44

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "doc")
                    .font(.title3)
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: displayScale, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}
