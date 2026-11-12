import CryptoKit
import LinkPresentation
import SwiftUI
import UIKit

/// The picture a page chose for itself (its preview image), fetched on the
/// phone from the page, never invented by the model. Kept on disk so each
/// find's picture is fetched once; pages without one are remembered too.
@MainActor
final class LeadImages {
    static let shared = LeadImages()

    private var memory: [URL: UIImage] = [:]
    private var missing: Set<URL> = []
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let folder = URL.cachesDirectory.appending(path: "feed-images", directoryHint: .isDirectory)

    func cached(_ url: URL) -> UIImage? { memory[url] }

    func image(for url: URL) async -> UIImage? {
        if let image = memory[url] { return image }
        if missing.contains(url) { return nil }
        if let task = inFlight[url] { return await task.value }
        let task = Task { await load(url) }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory[url] = image } else { missing.insert(url) }
        return image
    }

    /// Starts every find's picture as soon as a batch arrives, so they are
    /// there by the time the owner scrolls to them.
    func prefetch(_ urls: [URL]) {
        for url in urls { Task { _ = await image(for: url) } }
    }

    private func load(_ url: URL) async -> UIImage? {
        let file = folder.appending(path: Self.key(url))
        let none = file.appendingPathExtension("none")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        if FileManager.default.fileExists(atPath: none.path()) { return nil }

        let image = await fetch(url)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let image, let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: file)
        } else if image == nil {
            try? Data().write(to: none)
        }
        return image
    }

    private func fetch(_ url: URL) async -> UIImage? {
        let provider = LPMetadataProvider()
        provider.timeout = 12
        guard let metadata = try? await provider.startFetchingMetadata(for: url),
              let source = metadata.imageProvider,
              let image = await Self.loadImage(from: source)
        else { return nil }
        // Tiny images are logos and favicons, not pictures of the thing.
        guard min(image.size.width, image.size.height) >= 200 else { return nil }
        return image.preparingThumbnail(of: Self.fit(image.size, width: 1000)) ?? image
    }

    private nonisolated static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    private static func fit(_ size: CGSize, width: CGFloat) -> CGSize {
        guard size.width > width else { return size }
        return CGSize(width: width, height: (size.height * width / size.width).rounded())
    }

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}

/// A find's picture: a banner across the top of a lead card, or a square
/// beside the title of the others. Takes no room until there is a picture,
/// then fades in; a page with none leaves the card as text.
struct LeadImageView: View {
    enum Style { case banner, thumbnail }

    let url: URL
    var style: Style = .banner

    @State private var image: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL, style: Style = .banner) {
        self.url = url
        self.style = style
        _image = State(initialValue: LeadImages.shared.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Color.clear
                    .frame(width: style == .thumbnail ? 76 : nil, height: style == .thumbnail ? 76 : 176)
                    .overlay {
                        GeometryReader { frame in
                            let crop = Self.crop(image.size, into: frame.size)
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: crop.width, height: crop.height)
                                .offset(x: crop.minX, y: crop.minY)
                        }
                    }
                    .clipShape(.rect(cornerRadius: style == .thumbnail ? 10 : 0))
                    .transition(.opacity)
                    .accessibilityHidden(true)
            } else {
                // Something must be on screen for the task below to run.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            let loaded = await LeadImages.shared.image(for: url)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { image = loaded }
        }
    }

    /// Fills the frame. Tall pictures are usually people, whose faces sit about
    /// a third of the way down, so their crop keeps that band; the rest centre.
    static func crop(_ image: CGSize, into frame: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let scale = max(frame.width / image.width, frame.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let focus: CGFloat = image.height > image.width * 0.8 ? 0.3 : 0.5
        let y = min(0, max(frame.height - size.height, frame.height / 2 - size.height * focus))
        return CGRect(x: (frame.width - size.width) / 2, y: y, width: size.width, height: size.height)
    }
}
