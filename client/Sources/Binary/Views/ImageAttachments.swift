import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image waiting to be sent with a message.
struct PendingImage: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let mediaType: String
    let thumbnail: NSImage

    var wire: WireImage { WireImage(mediaType: mediaType, data: data.base64EncodedString()) }

    static func == (a: PendingImage, b: PendingImage) -> Bool { a.id == b.id }
}

/// Turns pasted, dropped or picked images into what the server accepts:
/// PNG / JPEG / GIF / WebP, at most 5 MB each, long side at most 2000 px.
enum ImageProcessor {
    static let maxPerMessage = 20
    static let maxSide = 2000
    static let maxBytes = 5_000_000
    static let jpegAbove = 3_500_000

    static func prepare(_ data: Data, type hint: UTType? = nil) -> PendingImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let type = hint ?? (CGImageSourceGetType(src) as String?).flatMap { UTType($0) }
        // Animated formats go as they are when small enough.
        if let type, type.conforms(to: .gif) || type == UTType("org.webmproject.webp"), data.count <= maxBytes,
           let thumb = thumbnail(src) {
            return PendingImage(data: data, mediaType: type.conforms(to: .gif) ? "image/gif" : "image/webp", thumbnail: thumb)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        var out = rep.representation(using: .png, properties: [:])
        var mediaType = "image/png"
        if let png = out, png.count > jpegAbove {
            out = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            mediaType = "image/jpeg"
        }
        guard let encoded = out, encoded.count <= maxBytes, let thumb = thumbnail(src) else { return nil }
        return PendingImage(data: encoded, mediaType: mediaType, thumbnail: thumb)
    }

    static func prepare(url: URL) -> PendingImage? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: url) else { return nil }
        return prepare(data, type: type)
    }

    private static func thumbnail(_ src: CGImageSource) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Image files or image data on the pasteboard. Text wins over image
    /// data, so pasting rich text still pastes text.
    static func images(from pb: NSPasteboard) -> [PendingImage] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let imgs = urls.compactMap(prepare(url:))
            if !imgs.isEmpty { return imgs }
            if !urls.isEmpty { return [] }
        }
        if pb.string(forType: .string) != nil { return [] }
        let types: [(NSPasteboard.PasteboardType, UTType?)] = [
            (.png, .png), (NSPasteboard.PasteboardType("public.jpeg"), .jpeg),
            (NSPasteboard.PasteboardType("com.compuserve.gif"), .gif),
            (NSPasteboard.PasteboardType("org.webmproject.webp"), UTType("org.webmproject.webp")),
            (.tiff, .tiff),
        ]
        for (t, ut) in types {
            if let d = pb.data(forType: t), let img = prepare(d, type: ut) { return [img] }
        }
        return []
    }

    /// Loads dropped items (files or image data).
    static func load(_ providers: [NSItemProvider], into add: @escaping @MainActor ([PendingImage]) -> Void) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let img = prepare(url: url) else { return }
                    Task { @MainActor in add([img]) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let img = prepare(data) else { return }
                    Task { @MainActor in add([img]) }
                }
            }
        }
    }

    /// Opens a file panel for picking images.
    @MainActor
    static func pick() -> [PendingImage] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = tr("Attach")
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(prepare(url:))
    }
}

// MARK: - Views

/// Thumbnails of images about to be sent, each with a remove button.
struct AttachmentStrip: View {
    @Binding var images: [PendingImage]
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(images) { img in
                    Image(nsImage: img.thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.c.border))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                images.removeAll { $0.id == img.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .help(tr("Remove"))
                        }
                        .help(img.mediaType + " · " + ByteCountFormatter.string(fromByteCount: Int64(img.data.count), countStyle: .file))
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
            .slimScrollers()
        }
        .scrollIndicators(.never)
    }
}

/// Catches ⌘V while `active` and takes images off the pasteboard; any other
/// paste goes to the text field as usual.
final class PasteCatcher {
    var active = false
    var onImages: (([PendingImage]) -> Void)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let imgs = ImageProcessor.images(from: .general)
            guard !imgs.isEmpty else { return event }
            self.onImages?(imgs)
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { remove() }
}

extension View {
    /// Accepts dropped image files and image data.
    func imageDrop(isTargeted: Binding<Bool>, add: @escaping @MainActor ([PendingImage]) -> Void) -> some View {
        onDrop(of: [.fileURL, .image], isTargeted: isTargeted) { providers in
            ImageProcessor.load(providers, into: add)
            return true
        }
    }
}

// MARK: - Images in the transcript

/// Loads an image a user message refers to.
struct ImageSource {
    var load: (String) async -> NSImage?
    var data: (String) async -> Data?
}

private struct ImageSourceKey: EnvironmentKey {
    static let defaultValue: ImageSource? = nil
}

extension EnvironmentValues {
    var imageSource: ImageSource? {
        get { self[ImageSourceKey.self] }
        set { self[ImageSourceKey.self] = newValue }
    }
}

/// A user-message image: thumbnail, click to view larger.
struct RemoteImageThumb: View {
    let key: String?
    var height: CGFloat = 240
    @Environment(\.imageSource) private var source
    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var failed = false
    @State private var viewing = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: height * 1.6, maxHeight: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.c.border))
                    .onTapGesture { viewing = true }
                    .help(tr("Click to enlarge"))
                    .sheet(isPresented: $viewing) {
                        ImageViewer(image: image, key: key)
                    }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                        .font(.system(size: 20))
                    if failed { Text(tr("Image unavailable")).font(theme.font(.small)) }
                }
                .foregroundStyle(theme.c.textFaint)
                .frame(width: 120, height: min(height, 90))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.c.surfaceAlt))
            }
        }
        .task(id: key) {
            guard let key, let source else { failed = true; return }
            image = await source.load(key)
            failed = image == nil
        }
    }
}

struct ImageViewer: View {
    let image: NSImage
    let key: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.imageSource) private var source
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 1100, maxHeight: 780)
                .padding(16)
            HStack {
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textMuted)
                Spacer()
                Button(tr("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                .buttonStyle(.themed(.secondary))
                Button(tr("Open in Preview")) { openInPreview() }
                    .buttonStyle(.themed(.secondary))
                Button(tr("Done")) { dismiss() }
                    .buttonStyle(.themed(.primary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(theme.c.background)
    }

    private func openInPreview() {
        Task {
            var data: Data? = nil
            if let key, let source { data = await source.data(key) }
            if data == nil, let tiff = image.tiffRepresentation { data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) }
            guard let data else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("binary-image-\(UUID().uuidString.prefix(8)).png")
            try? data.write(to: url)
            NSWorkspace.shared.open(url)
        }
    }
}
