import Foundation
import Observation

/// Unsent composer text and images for existing and new sessions, so switching (or
/// quitting) doesn't lose what was typed. Text is saved to drafts.json (0600,
/// next to servers.json); images only live for this run of the app.
@MainActor
@Observable
final class ComposerDrafts {
    static let shared = ComposerDrafts()

    private var texts: [String: String] = [:]
    private var images: [String: [PendingImage]] = [:]
    private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL = ClientFiles.url("drafts.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            texts = saved
        }
    }

    private static func key(_ ref: SessionRef?) -> String {
        guard let ref else { return "new-session" }
        return "\(ref.server.uuidString)/\(ref.session)"
    }

    func text(for ref: SessionRef?) -> String { texts[Self.key(ref)] ?? "" }
    func images(for ref: SessionRef?) -> [PendingImage] { images[Self.key(ref)] ?? [] }

    func setText(_ text: String, for ref: SessionRef?) {
        let k = Self.key(ref)
        let value = text.isEmpty ? nil : text
        guard texts[k] != value else { return }
        texts[k] = value
        scheduleSave()
    }

    func setImages(_ list: [PendingImage], for ref: SessionRef?) {
        images[Self.key(ref)] = list.isEmpty ? nil : list
    }

    var newSessionText: String {
        get { text(for: nil) }
        set { setText(newValue, for: nil) }
    }

    var newSessionImages: [PendingImage] {
        get { images(for: nil) }
        set { setImages(newValue, for: nil) }
    }

    /// Writes soon after the last keystroke, and right away at quit.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if !Task.isCancelled { self?.save() }
        }
    }

    func save() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(texts) else { return }
        ClientFiles.write(data, to: fileURL, private: true)
    }
}
