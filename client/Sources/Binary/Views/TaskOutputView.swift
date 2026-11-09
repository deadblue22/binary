import SwiftUI

struct TaskOutput: Decodable {
    var text: String
    var truncated: Bool
}

struct TaskOutputRequest: Identifiable {
    var session: SessionRef
    var task: String
    var title: String
    var id: String { task }
}

struct TaskOutputView: View {
    let request: TaskOutputRequest
    @Environment(ServerStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var output: TaskOutput?
    @State private var error: String?

    private var connection: ServerConnection? { store.connection(request.session.server) }
    private var running: Bool {
        connection?.sessions[request.session.session]?.tasks?.contains { $0.id == request.task } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(tr("Command output"), systemImage: "terminal")
                    .font(theme.font(.headline))
                Spacer()
                Button(tr("Copy")) { if let output { copy(output.text) } }
                    .disabled(output?.text.isEmpty != false)
                Button(tr("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if !request.title.isEmpty {
                Text(request.title).font(theme.font(.callout)).foregroundStyle(theme.c.textMuted)
                    .lineLimit(2)
            }
            if output?.truncated == true {
                Text(tr("Showing the last 64 KiB")).font(theme.font(.caption)).foregroundStyle(theme.c.textMuted)
            }
            if let error {
                Text(error).font(theme.font(.caption)).foregroundStyle(theme.c.danger)
            }
            ScrollView {
                if let output {
                    Text(verbatim: output.text.isEmpty ? tr("No output yet") : output.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else if error == nil {
                    ProgressView().padding(12)
                }
            }
            .defaultScrollAnchor(.bottom)
            .background(theme.c.code)
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 360)
        #endif
        .task(id: running) {
            guard let connection else {
                error = tr("Server unavailable")
                return
            }
            repeat {
                do {
                    let latest = try await connection.taskOutput(request.session.session, task: request.task)
                    guard !Task.isCancelled else { return }
                    output = latest
                    error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                guard running else { return }
                try? await Task.sleep(for: .seconds(2))
            } while !Task.isCancelled
        }
    }
}
