import AppKit
import SwiftUI
import WebKit

/// A file a message links to, opened in Binary instead of handed to the system
/// (relative paths mean nothing to Finder, and the file may be on another machine).
struct FilePreviewRequest: Identifiable, Equatable {
    let server: UUID
    let session: String
    /// As written in the message: absolute, ~/…, or relative to the session's folder.
    let path: String
    var id: String { "\(server.uuidString)|\(session)|\(path)" }
}

/// What a link in a message opens, given the session it is in.
struct FileLinkHandler {
    var open: (URL) -> Void
}

private struct FileLinkHandlerKey: EnvironmentKey {
    static let defaultValue: FileLinkHandler? = nil
}

extension EnvironmentValues {
    var fileLinkHandler: FileLinkHandler? {
        get { self[FileLinkHandlerKey.self] }
        set { self[FileLinkHandlerKey.self] = newValue }
    }
}

enum FileLinks {
    /// Web and mail links go to the system; anything else is a file path.
    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme != "file"
    }

    /// The path a link names: percent-decoded, without a trailing ":line" or "#L12".
    static func path(of url: URL) -> String {
        var p = url.scheme?.lowercased() == "file" ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString)
        if let hash = p.firstIndex(of: "#") { p = String(p[..<hash]) }
        if let r = p.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { p.removeSubrange(r) }
        return p
    }

    /// The handler for links in one session's messages.
    @MainActor
    static func handler(server: UUID, session: String, nav: Navigation) -> FileLinkHandler {
        FileLinkHandler { url in
            if isExternal(url) {
                NSWorkspace.shared.open(url)
            } else {
                nav.filePreview = FilePreviewRequest(server: server, session: session, path: path(of: url))
            }
        }
    }
}

/// binary-file://cwd/<relative path> and binary-file://root/<absolute path>:
/// pages load their relative assets through the same scheme, from the server.
final class FileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "binary-file"
    let conn: ServerConnection
    let session: String
    private var stopped = Set<ObjectIdentifier>()

    init(conn: ServerConnection, session: String) {
        self.conn = conn
        self.session = session
    }

    static func url(for path: String) -> URL? {
        let isAbsolute = path.hasPrefix("/")
        let rest = (isAbsolute ? String(path.dropFirst()) : path)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(scheme)://\(isAbsolute ? "root" : "cwd")/\(rest)")
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
        let path = url.host == "root" ? "/" + rel : rel
        let id = ObjectIdentifier(task)
        Task { @MainActor in
            do {
                let (data, mime) = try await conn.file(session: session, path: path)
                guard !stopped.contains(id) else { return }
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            } catch {
                guard !stopped.contains(id) else { return }
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

struct FileWebView: NSViewRepresentable {
    let conn: ServerConnection
    let session: String
    let path: String
    /// Why the file couldn't be shown (missing, too large, server offline).
    @Binding var failure: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: FileWebView
        init(_ parent: FileWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.failure = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.failure = error.localizedDescription
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(FileSchemeHandler(conn: conn, session: session), forURLScheme: FileSchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        if let url = FileSchemeHandler.url(for: path) { web.load(URLRequest(url: url)) }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}
}

/// The preview window's content: the file rendered by WebKit (images, HTML,
/// PDF, SVG, text), with its name and a way to open it outside Binary.
struct FilePreviewView: View {
    let request: FilePreviewRequest
    @Environment(ServerStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    private var conn: ServerConnection? { store.connection(request.server) }

    /// On this Mac, the absolute path, for Open With….
    private var localPath: String? {
        guard let conn, conn.isLocal else { return nil }
        let p = (request.path as NSString).expandingTildeInPath
        if p.hasPrefix("/") { return p }
        guard let cwd = conn.sessions[request.session]?.cwd else { return nil }
        return (cwd as NSString).appendingPathComponent(p)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(theme.c.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text((request.path as NSString).lastPathComponent)
                        .font(theme.font(.callout).weight(.semibold))
                        .foregroundStyle(theme.c.text)
                    Text(request.path)
                        .font(theme.font(.small))
                        .foregroundStyle(theme.c.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let local = localPath {
                    Button(tr("Open in Default App")) { NSWorkspace.shared.open(URL(fileURLWithPath: local)) }
                        .buttonStyle(.themed(.secondary, compact: true))
                    Button(tr("Show in Finder")) { NSWorkspace.shared.selectFile(local, inFileViewerRootedAtPath: "") }
                        .buttonStyle(.themed(.secondary, compact: true))
                }
                Button(tr("Close")) { dismiss() }
                    .buttonStyle(.themed(.primary, compact: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(theme.c.border).frame(height: 1)
            if let conn {
                FileWebView(conn: conn, session: request.session, path: request.path, failure: $failure)
                    .overlay {
                        if let failure {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle").font(.system(size: 26))
                                Text(tr("Couldn't open the file")).font(theme.font(.headline))
                                Text(failure).font(theme.font(.callout)).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(theme.c.textMuted)
                            .padding(30)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(theme.c.background)
                        }
                    }
            } else {
                Text(tr("The server isn't connected"))
                    .foregroundStyle(theme.c.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 760)
        .background(theme.c.background)
    }
}
