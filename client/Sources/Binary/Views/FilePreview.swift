import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

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
                openExternal(url)
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
                var (data, mime) = try await conn.file(session: session, path: path)
                guard !stopped.contains(id) else { return }
                #if os(iOS)
                // WebKit shows a text file at desktop width, shrunk to fit the
                // phone: give it a page sized for the screen instead.
                if mime.hasPrefix("text/") && mime != "text/html" && url == task.request.mainDocumentURL {
                    (data, mime) = (Self.textPage(data), "text/html")
                }
                #endif
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            } catch {
                guard !stopped.contains(id) else { return }
                task.didFailWithError(error)
            }
        }
    }

    #if os(iOS)
    /// Plain text as a phone-sized page that wraps long lines.
    private static func textPage(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return Data(("""
            <!doctype html><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            :root { color-scheme: light dark }
            body { margin: 14px; font: 13px ui-monospace, Menlo, monospace }
            pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: inherit }
            </style>
            <pre>
            """ + text + "</pre>").utf8)
    }
    #endif

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

#if os(macOS)
typealias WebViewRepresentable = NSViewRepresentable
#else
typealias WebViewRepresentable = UIViewRepresentable
#endif

struct FileWebView: WebViewRepresentable {
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

    private func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(FileSchemeHandler(conn: conn, session: session), forURLScheme: FileSchemeHandler.scheme)
        #if os(iOS)
        // Pages without a viewport (plain text, most generated HTML) would be
        // laid out 980 px wide and shrunk to fit the phone.
        config.userContentController.addUserScript(WKUserScript(source: """
            if (!document.querySelector('meta[name=viewport]') && document.head) {
              const m = document.createElement('meta');
              m.name = 'viewport';
              m.content = 'width=device-width, initial-scale=1';
              document.head.appendChild(m);
            }
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        #endif
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        #endif
        web.navigationDelegate = context.coordinator
        if let url = FileSchemeHandler.url(for: path) { web.load(URLRequest(url: url)) }
        return web
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) {}
    #endif
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

    #if os(macOS)
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
            content
        }
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 760)
        .background(theme.c.background)
    }
    #else
    var body: some View {
        NavigationStack {
            content
                .background(theme.c.background)
                .navigationTitle((request.path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tr("Close")) { dismiss() }
                    }
                }
        }
    }
    #endif

    @ViewBuilder
    private var content: some View {
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
}
