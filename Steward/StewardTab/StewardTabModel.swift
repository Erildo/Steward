import SwiftUI
import Observation
import UIKit

/// One thing Steward can reach: an app on the phone, an account, or a
/// website the owner signed into through the live view.
struct ConnectedApp: Identifiable, Hashable {
    enum Kind: Hashable { case app, website }

    /// What Steward may do there. Sending always waits for a yes, so it is
    /// never a switch.
    enum Ability: String, CaseIterable, Hashable {
        case read, draft, add, send

        var title: String {
            switch self {
            case .read: "Read"
            case .draft: "Write drafts"
            case .add: "Add events"
            case .send: "Send"
            }
        }
    }

    let id: String
    var name: String
    var kind: Kind
    var systemImage: String
    var color: Color
    /// The account or address it is connected as, when there is one.
    var account: String?
    /// What each ability means here, in the owner's words.
    var explains: [Ability: String]
    var allowed: Set<Ability>
    var lastUsed: Date?
    /// The task it was last used for.
    var lastUsedFor: String?
    /// A sign-in that ran out: Steward can't reach it until the owner signs in again.
    var needsSignIn = false

    var abilities: [Ability] { Ability.allCases.filter { explains[$0] != nil } }

    /// "Reads, writes drafts" for the list row.
    var summary: String {
        if needsSignIn { return "Sign-in ran out" }
        let parts = abilities.filter { $0 != .send && allowed.contains($0) }.map { ability -> String in
            switch ability {
            case .read: "reads"
            case .draft: "writes drafts"
            case .add: "adds events"
            case .send: ""
            }
        }
        var text = parts.isEmpty ? "Connected, nothing allowed" : parts.joined(separator: ", ")
        if abilities.contains(.send) { text += ", sends with your yes" }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// A document Steward holds: one the owner gave it, or one Steward made.
struct StewardFile: Identifiable, Hashable {
    enum Origin: String, CaseIterable, Identifiable {
        case steward, owner
        var id: Self { self }
        var title: String {
            switch self {
            case .steward: "Made by Steward"
            case .owner: "From you"
            }
        }
    }

    var id: URL { url }
    let url: URL
    var name: String
    var origin: Origin
    /// What it is, in a word or two: "Letter", "Proof", "Bill".
    var kind: String
    /// The task it belongs to, by title, and its id when Tasks still has it.
    var taskTitle: String?
    var taskID: UUID?
    var date: Date
}

/// Everything the Steward tab shows: what Steward can reach and what it holds.
/// The rules and settings live in `@AppStorage`, next to where they're used.
@Observable
final class StewardTabModel {
    var apps: [ConnectedApp]
    /// Apps the owner could connect, shown in the Connect sheet.
    var available: [ConnectedApp]
    private(set) var files: [StewardFile]
    let isSample: Bool

    init(apps: [ConnectedApp], available: [ConnectedApp], files: [StewardFile], isSample: Bool) {
        self.apps = apps
        self.available = available
        self.files = files
        self.isSample = isSample
    }

    func files(_ origin: StewardFile.Origin) -> [StewardFile] {
        files.filter { $0.origin == origin }.sorted { $0.date > $1.date }
    }

    // MARK: Apps

    func app(_ id: String) -> ConnectedApp? { apps.first { $0.id == id } }

    func setAllowed(_ ability: ConnectedApp.Ability, _ on: Bool, for id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        if on { apps[index].allowed.insert(ability) } else { apps[index].allowed.remove(ability) }
    }

    /// Until real connections exist, connecting moves the app across and
    /// allows reading, the least it can do.
    func connect(_ app: ConnectedApp) {
        available.removeAll { $0.id == app.id }
        var app = app
        app.allowed = Set(app.abilities.filter { $0 == .read })
        apps.append(app)
    }

    func disconnect(_ id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        var app = apps.remove(at: index)
        app.lastUsed = nil
        app.lastUsedFor = nil
        app.needsSignIn = false
        if app.kind == .app { available.insert(app, at: 0) }
    }

    func signedInAgain(_ id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[index].needsSignIn = false
    }

    // MARK: Files

    private static let ownerFolder = URL.documentsDirectory.appending(path: "Files/From you", directoryHint: .isDirectory)

    /// Copies a file the owner picked into Steward's folder, so it stays when
    /// the original moves.
    func add(_ picked: URL) throws {
        let reading = picked.startAccessingSecurityScopedResource()
        defer { if reading { picked.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: Self.ownerFolder, withIntermediateDirectories: true)
        var target = Self.ownerFolder.appending(path: picked.lastPathComponent)
        var copy = 2
        while FileManager.default.fileExists(atPath: target.path()) {
            target = Self.ownerFolder.appending(path: "\(picked.deletingPathExtension().lastPathComponent) \(copy).\(picked.pathExtension)")
            copy += 1
        }
        try FileManager.default.copyItem(at: picked, to: target)
        try? (target as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        files.append(StewardFile(url: target, name: target.deletingPathExtension().lastPathComponent,
                                 origin: .owner, kind: Self.kind(of: target), date: .now))
    }

    /// Removes a file from the list now and from disk once the undo is gone.
    func remove(_ file: StewardFile) {
        files.removeAll { $0.id == file.id }
    }

    func restore(_ file: StewardFile) {
        files.append(file)
    }

    /// Deletes for good, after the undo passed.
    func purge(_ file: StewardFile) {
        guard !files.contains(file) else { return }
        try? FileManager.default.removeItem(at: file.url)
    }

    func removeEverything() {
        for file in files { try? FileManager.default.removeItem(at: file.url) }
        files = []
        for app in apps where app.kind == .app { disconnect(app.id) }
        apps = []
    }

    static func kind(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": "PDF"
        case "jpg", "jpeg", "png", "heic": "Photo"
        case "txt", "rtf", "md": "Text"
        default: url.pathExtension.uppercased()
        }
    }
}

// MARK: Launch

extension StewardTabModel {
    /// Like the other tabs: `-uiState steward` (and the debug demo) shows
    /// sample apps and files; `-uiState stewardEmpty` and real launches show
    /// what's really there, which is nothing connected yet.
    @MainActor static func launch(tasks: TasksModel) -> StewardTabModel {
        switch UserDefaults.standard.string(forKey: "uiState") {
        case "steward", "demo": StewardTabSample.model(tasks: tasks)
        default: real()
        }
    }

    static func real() -> StewardTabModel {
        let folder = ownerFolder
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let files = urls.map { url in
            StewardFile(url: url, name: url.deletingPathExtension().lastPathComponent, origin: .owner, kind: kind(of: url),
                        date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now)
        }
        return StewardTabModel(apps: [], available: StewardTabSample.phoneApps, files: files, isSample: false)
    }
}

/// Demo content for `-uiState steward`. Made up, labelled "Sample", and tied
/// to the sample errands in Tasks so "Open task" lands somewhere real.
enum StewardTabSample {
    /// What the phone itself offers. Connecting is not wired yet.
    static let phoneApps: [ConnectedApp] = [
        ConnectedApp(id: "calendar", name: "Calendar", kind: .app, systemImage: "calendar", color: .red,
                     explains: [.read: "See when you're free, to book and reschedule.",
                                .add: "Put appointments and deadlines in your calendar."],
                     allowed: []),
        ConnectedApp(id: "contacts", name: "Contacts", kind: .app, systemImage: "person.crop.circle", color: .gray,
                     explains: [.read: "Find an address or number when a form asks for one."],
                     allowed: []),
        ConnectedApp(id: "photos", name: "Photos", kind: .app, systemImage: "photo.on.rectangle", color: .orange,
                     explains: [.read: "Only the photos you pick, like a receipt or a meter."],
                     allowed: []),
        ConnectedApp(id: "shortcuts", name: "Shortcuts", kind: .app, systemImage: "square.2.layers.3d", color: .indigo,
                     explains: [.read: "Run the shortcuts you choose, like paying through your bank's app."],
                     allowed: []),
        ConnectedApp(id: "outlook", name: "Outlook", kind: .app, systemImage: "envelope.badge", color: .blue,
                     explains: [.read: "Find bills, receipts and replies from companies.",
                                .draft: "Write replies for you to check.",
                                .send: "Send a message once you say yes."],
                     allowed: []),
    ]

    @MainActor static func model(tasks: TasksModel) -> StewardTabModel {
        let now = Date.now
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        func task(_ title: String) -> UUID? { tasks.cases.first { $0.title == title }?.id }

        var calendar = phoneApps[0]
        calendar.allowed = [.read, .add]
        calendar.lastUsed = ago(26)
        calendar.lastUsedFor = "Cancel gym membership"
        var photos = phoneApps[2]
        photos.allowed = [.read]
        photos.lastUsed = ago(7)
        photos.lastUsedFor = "Dispute estimated energy bill"

        let apps = [
            ConnectedApp(id: "gmail", name: "Gmail", kind: .app, systemImage: "envelope", color: .blue,
                         account: "alex.weber@mail.example",
                         explains: [.read: "Find bills, receipts and replies from companies.",
                                    .draft: "Write replies for you to check.",
                                    .send: "Send a message once you say yes."],
                         allowed: [.read, .draft], lastUsed: ago(2), lastUsedFor: "Refund for faulty headphones"),
            calendar,
            photos,
            ConnectedApp(id: "fitworld.example", name: "fitworld.example", kind: .website, systemImage: "globe", color: .teal,
                         account: "Member 48213",
                         explains: [.read: "Check your membership and notice period."],
                         allowed: [.read], lastUsed: ago(30), lastUsedFor: "Cancel gym membership"),
            ConnectedApp(id: "fibrelink.example", name: "fibrelink.example", kind: .website, systemImage: "globe", color: .teal,
                         account: "Account FL-2290",
                         explains: [.read: "See outage credits and your complaint's status."],
                         allowed: [.read], lastUsed: ago(190), lastUsedFor: "Complain about broadband outage",
                         needsSignIn: true),
        ]
        let available = phoneApps.filter { app in !apps.contains { $0.id == app.id } }

        let folder = URL.cachesDirectory.appending(path: "Sample files", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String, _ origin: StewardFile.Origin, _ kind: String, _ taskTitle: String, _ hours: Double, _ body: String) -> StewardFile {
            let url = folder.appending(path: name + ".pdf")
            if !FileManager.default.fileExists(atPath: url.path()) { SamplePDF.write(title: name, body: body, to: url) }
            return StewardFile(url: url, name: name, origin: origin, kind: kind, taskTitle: taskTitle, taskID: task(taskTitle), date: ago(hours))
        }

        let files = [
            file("Cancellation letter to FitWorld", .steward, "Letter", "Cancel gym membership", 2.4,
                 "Hello,\n\nI'm cancelling my membership 48213 with notice, as section 7 of your terms allows. Please confirm in writing the date it ends.\n\nThank you,\nAlex Weber"),
            file("Refund request to SoundHouse", .steward, "Letter", "Refund for faulty headphones", 96,
                 "Hello,\n\nThe headphones I bought on 2 October stopped charging after nine days. Under the Consumer Rights Act 2015 I'm asking for a full refund of £89.00 within 14 days.\n\nThank you,\nAlex Weber"),
            file("Formal complaint to Fibrelink", .steward, "Letter", "Complain about broadband outage", 168,
                 "Hello,\n\nMy broadband (account FL-2290) was down from 28 October to 2 November. I'd like the outage credit your terms promise and a written explanation.\n\nThank you,\nAlex Weber"),
            file("Fresh Fork confirms the cancellation", .steward, "Proof", "Cancel meal kit subscription", 216,
                 "Saved reply from help@freshfork.example:\n\n\"We can confirm your subscription has been cancelled and no further payments will be taken.\""),
            file("Energy bill, October", .owner, "Bill", "Dispute estimated energy bill", 72,
                 "Stadtwerk Nord\nEstimated reading: 18,400 kWh\nAmount due: €412.60"),
            file("SoundHouse receipt", .owner, "Receipt", "Refund for faulty headphones", 120,
                 "SoundHouse order 7731\nWireless headphones: £89.00\nPaid 2 October"),
            file("FitWorld contract", .owner, "Contract", "Cancel gym membership", 28,
                 "FitWorld Berlin membership 48213\nSection 7: either side may cancel with four weeks' notice to the end of a month."),
        ]
        return StewardTabModel(apps: apps, available: available, files: files, isSample: true)
    }
}

/// A one-page PDF of plain text, marked as a sample.
private enum SamplePDF {
    static func write(title: String, body: String, to url: URL) {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            let margin: CGFloat = 64
            let width = page.width - margin * 2
            let note = NSAttributedString(string: "Sample file: not a real document.", attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: UIColor.systemGray,
            ])
            note.draw(at: CGPoint(x: margin, y: 40))
            let heading = NSAttributedString(string: title, attributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: UIColor.black,
            ])
            heading.draw(with: CGRect(x: margin, y: margin + 10, width: width, height: 60), options: .usesLineFragmentOrigin, context: nil)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            let text = NSAttributedString(string: body, attributes: [
                .font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkGray, .paragraphStyle: style,
            ])
            text.draw(with: CGRect(x: margin, y: margin + 60, width: width, height: page.height - margin * 2 - 60),
                      options: .usesLineFragmentOrigin, context: nil)
        }
        try? data.write(to: url, options: .atomic)
    }
}
