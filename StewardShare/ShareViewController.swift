import SwiftUI
import UIKit
import UniformTypeIdentifiers
import StewardCore

/// The Share button's "Steward" target: takes a link (and the page title, when
/// the app gives one), asks why the owner is sharing it, and drops it into the
/// feed's inbox. Nothing leaves the phone here.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        overrideUserInterfaceStyle = Appearance.current.interfaceStyle
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let pageTitle = items.lazy.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty }
        let providers = Providers(list: items.flatMap { $0.attachments ?? [] })

        Task { [weak self] in
            let found = await Self.extract(from: providers)
            guard let self else { return }
            show(SharePanel(
                url: found.url,
                title: Self.title(pageTitle: pageTitle, text: found.text, url: found.url),
                send: { [weak self] item in self?.send(item) },
                cancel: { [weak self] in self?.cancel() }
            ))
        }
    }

    private func show(_ panel: SharePanel) {
        let host = UIHostingController(rootView: panel)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func send(_ item: SharedItem) {
        do {
            try FeedStore(folder: FeedFolder.url).enqueue(item)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    // MARK: Reading what was shared

    /// Item providers are documented as safe to use from any thread, but aren't
    /// marked `Sendable`.
    nonisolated private struct Providers: @unchecked Sendable {
        let list: [NSItemProvider]
    }

    nonisolated private struct Found: Sendable {
        var url: URL?
        var text: String?
    }

    /// Off the main actor: item providers call back on their own queues.
    nonisolated private static func extract(from providers: Providers) async -> Found {
        var found = Found()
        for provider in providers.list {
            if found.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                found.url = await load(provider, UTType.url) { ($0 as? URL) ?? ($0 as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } }
            }
            if found.text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                found.text = await load(provider, UTType.plainText) { $0 as? String }
            }
        }
        // Many apps share "Some title https://…" as plain text only.
        if found.url == nil, let text = found.text {
            found.url = firstLink(in: text)
        }
        if found.url?.isFileURL == true { found.url = nil }
        return found
    }

    nonisolated private static func load<T: Sendable>(_ provider: NSItemProvider, _ type: UTType, _ convert: @escaping @Sendable (Any?) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                continuation.resume(returning: convert(item))
            }
        }
    }

    nonisolated private static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    private static func title(pageTitle: String?, text: String?, url: URL?) -> String {
        if let pageTitle, !pageTitle.isEmpty { return pageTitle }
        if var text {
            if let link = url?.absoluteString { text = text.replacingOccurrences(of: link, with: "") }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(200)) }
        }
        return url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
    }
}

private struct SharePanel: View {
    let url: URL?
    @State var title: String
    let send: (SharedItem) -> Void
    let cancel: () -> Void

    @State private var feeling: SharedItem.Feeling?
    @State private var note = ""

    init(url: URL?, title: String, send: @escaping (SharedItem) -> Void, cancel: @escaping () -> Void) {
        self.url = url
        self._title = State(initialValue: title)
        self.send = send
        self.cancel = cancel
    }

    private var canSend: Bool {
        url != nil || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.headline)
                    if let host = url?.host() {
                        Text(host.replacingOccurrences(of: "www.", with: ""))
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                }

                Section("Why are you sharing it?") {
                    HStack(spacing: 8) {
                        ForEach(SharedItem.Feeling.allCases, id: \.self) { option in
                            let selected = feeling == option
                            Button {
                                feeling = selected ? nil : option
                            } label: {
                                Text(option.label)
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(selected ? Palette.onOrange : Palette.ink)
                                    .background(selected ? Palette.orange : Palette.stewardBubble, in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField("Anything to add? (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("Steward uses this to find more you'll like. It stays on your iPhone.")
                }
            }
            .navigationTitle("Send to Steward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send(SharedItem(
                            url: url,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url?.absoluteString ?? "") : title.trimmingCharacters(in: .whitespacesAndNewlines),
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                            feeling: feeling,
                            date: .now
                        ))
                    }
                    .disabled(!canSend)
                }
            }
        }
        .tint(Palette.orange)
    }
}
