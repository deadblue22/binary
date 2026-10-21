import Foundation

/// Unsent composer text and images per session, so switching sessions (or
/// quitting) doesn't lose what was typed. Text is saved to drafts.json (0600,
/// next to servers.json); images only live for this run of the app.
@MainActor
final class ComposerDrafts {
    static let shared = ComposerDrafts()

    private var texts: [String: String] = [:]
    private var images: [String: [PendingImage]] = [:]
    private let fileURL = ClientFiles.url("drafts.json")
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            texts = saved
        }
    }

    private static func key(_ ref: SessionRef) -> String { "\(ref.server.uuidString)/\(ref.session)" }

    func text(for ref: SessionRef) -> String { texts[Self.key(ref)] ?? "" }
    func images(for ref: SessionRef) -> [PendingImage] { images[Self.key(ref)] ?? [] }

    func setText(_ text: String, for ref: SessionRef) {
        let k = Self.key(ref)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard texts[k] != value else { return }
        texts[k] = value
        scheduleSave()
    }

    func setImages(_ list: [PendingImage], for ref: SessionRef) {
        images[Self.key(ref)] = list.isEmpty ? nil : list
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
