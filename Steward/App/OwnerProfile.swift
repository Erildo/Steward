import SwiftUI
import PhotosUI
import Observation

/// Who the owner is, as the app shows them: a name and an optional photo.
///
/// A stand-in until sign-up exists: kept on the phone only (the name in
/// settings, the photo as a file in the app's documents).
@Observable
final class OwnerProfile {
    private static let nameKey = "owner.name"
    private static let photoURL = URL.documentsDirectory.appending(path: "owner-photo.jpg")

    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }
    private(set) var photo: UIImage?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        // Sample launches get the sample owner, so the avatars have initials.
        name = stored.isEmpty && UserDefaults.standard.string(forKey: "uiState") != nil ? "Alex Weber" : stored
        photo = (try? Data(contentsOf: Self.photoURL)).flatMap(UIImage.init(data:))
    }

    /// "AW" from "Alex Weber"; empty when there's no name yet.
    var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }

    func setPhoto(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else {
            photo = nil
            try? FileManager.default.removeItem(at: Self.photoURL)
            return
        }
        // Small is enough for an avatar, and keeps the file light.
        let side: CGFloat = 400
        let scale = side / min(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        photo = resized
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: Self.photoURL, options: [.atomic, .completeFileProtection])
    }
}

/// The owner's face in the app: their photo, their initials, or a plain person.
struct OwnerAvatar: View {
    var size: CGFloat = 36

    @Environment(OwnerProfile.self) private var profile

    var body: some View {
        Group {
            if let photo = profile.photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if !profile.initials.isEmpty {
                Text(profile.initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: size, height: size)
        .background(Palette.ownerTint, in: .circle)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// Edits the stand-in profile. Sign-up will replace this.
struct ProfileSheet: View {
    @Environment(OwnerProfile.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @AppStorage(Appearance.storageKey, store: Appearance.store) private var appearance = Appearance.light

    var body: some View {
        @Bindable var profile = profile
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        OwnerAvatar(size: 88)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    PhotosPicker(profile.photo == nil ? "Choose Photo" : "Change Photo", selection: $pick, matching: .images)
                    if profile.photo != nil {
                        Button("Remove Photo", role: .destructive) { profile.setPhoto(nil) }
                    }
                }
                Section {
                    TextField("Your name", text: $profile.name)
                        .textContentType(.name)
                        .submitLabel(.done)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown on your tasks. Kept on this phone until sign-in is ready.")
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: pick) {
                guard let pick else { return }
                Task {
                    let data = try? await pick.loadTransferable(type: Data.self)
                    profile.setPhoto(data)
                    self.pick = nil
                }
            }
        }
    }
}
