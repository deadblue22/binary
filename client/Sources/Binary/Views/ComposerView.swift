import SwiftUI

struct ComposerView: View {
    let controller: SessionController
    @Binding var images: [PendingImage]
    @Environment(\.theme) private var theme
    @Environment(Navigation.self) private var nav
    @State private var text = ""
    @State private var sending = false
    @State private var paste = PasteCatcher()
    /// An input method is composing text the binding doesn't have yet.
    @State private var composing = false
    @State private var composingWatcher = ComposingWatcher()
    @State private var limitNotice = false
    /// The level ⌘[ / ⌘] last moved to, shown for a moment.
    @State private var effortHUD: String?
    @State private var hudSerial = 0
    /// Messages queued from here: the full text and images, so Edit can put
    /// them back (the server only keeps a preview).
    @State private var drafts: [String: (text: String, images: [PendingImage])] = [:]
    /// Just queued and maybe not in the summary yet, shown for a few seconds.
    @State private var justQueued: [QueuedMessage] = []
    @FocusState private var focused: Bool

    private var summary: SessionSummary? { controller.summary }
    private var busy: Bool { summary?.status.isBusy == true }
    /// Another program also has the session open (newer servers say which).
    private var hold: ExternalHold? { summary?.hold }
    /// A turn is running there: what is sent here waits for it to end.
    private var heldBusy: Bool { hold?.working == true }
    /// Queued messages: the server's list, plus ones it hasn't reported yet.
    private var queued: [QueuedMessage] {
        let server = summary?.queued ?? []
        return server + justQueued.filter { q in !server.contains { $0.id == q.id } }
    }
    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && !sending
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.isPrimary ? 10 : 16, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            if let hold {
                Label(heldHint(hold), systemImage: hold.icon)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.textFaint)
            } else if summary?.status == .external {
                Label(tr("This session is running in another program (a terminal, IDE or the desktop app). Sending here starts a second process on the same transcript, and the conversation may diverge."),
                      systemImage: "exclamationmark.triangle")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.warning)
            } else if summary?.status == .error, let e = summary?.error {
                Label(e, systemImage: "xmark.octagon")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.danger)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            ForEach(queued) { q in
                QueuedChip(item: q, holder: hold?.shortName,
                           onEdit: drafts[q.id] == nil ? nil : { edit(q) },
                           onCancel: { cancel(q) })
            }
            if !images.isEmpty {
                AttachmentStrip(images: $images)
            }
            if limitNotice {
                Text(tr("Up to \(ImageProcessor.maxPerMessage) images per message."))
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.c.warning)
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachButton { add($0) }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty && !composing {
                        // Drawn here so it takes the theme's faint color.
                        theme.placeholder(placeholder)
                            .font(theme.font(.body))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(theme.font(.body))
                        .foregroundStyle(theme.c.text)
                        .lineSpacing(theme.lineSpacing * 0.6)
                        .lineLimit(1...12)
                        .focused($focused)
                        .onSubmit(submit)
                        .shiftReturnNewline(when: focused)
                        .accessibilityLabel(placeholder)
                }
                .padding(.vertical, 5)
                if busy {
                    Button {
                        Task { await controller.interrupt() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: theme.sendButton, height: theme.sendButton)
                            .background(Circle().fill(theme.c.danger.opacity(0.14)))
                            .foregroundStyle(theme.c.danger)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help(tr("Interrupt this turn (⌘.)"))
                    .accessibilityLabel(tr("Interrupt"))
                }
                if hold != nil {
                    // Also open elsewhere: a fork continues here and leaves
                    // the original to that program.
                    Menu {
                        Button(tr("Fork and Continue Here")) { submit(fork: true) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 28)
                            .foregroundStyle(theme.c.textFaint)
                    }
                    .plainMenu()
                    .disabled(!canSend)
                    .help(tr("More ways to send"))
                    .accessibilityLabel(tr("More ways to send"))
                }
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: theme.sendButton, height: theme.sendButton)
                        .background(Circle().fill(canSend ? theme.c.accent : theme.c.border))
                        .foregroundStyle(canSend ? theme.c.onAccent : theme.c.textFaint)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(heldBusy ? tr("Queue: sent when \(hold?.shortName ?? "") finishes this turn (↩)")
                      : busy ? tr("Queue: sent after the current turn") : tr("Send (↩) · ⇧↩ or ⌥↩ for a new line"))
                .accessibilityLabel(tr("Send"))
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(shape.fill(theme.c.input))
            .overlay(shape.strokeBorder(focused ? theme.c.focus.opacity(0.8) : theme.c.border, lineWidth: focused ? 1.5 : 1))
            .shadow(color: theme.c.shadow, radius: focused ? 8 : 4, y: 2)
            .contentShape(shape)
            .onTapGesture { focused = true }
            SessionControls(controller: controller)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, theme.gutter)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: theme.readingWidth)
        .overlay(alignment: .topTrailing) {
            // A zero-size anchor at the top corner; the HUD grows up from it.
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .bottomTrailing) {
                    if let effortHUD {
                        EffortHUD(level: effortHUD, levels: controller.effortLevels)
                            .fixedSize()
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    }
                }
                .padding(.trailing, theme.gutter)
        }
        .frame(maxWidth: .infinity)
        .background(theme.c.background)
        .onChange(of: nav.effortStep) { _, step in
            guard let level = controller.stepEffort(step.delta) else { return }
            showEffortHUD(level)
        }
        #if os(macOS)
        .task {
            // Focus after a beat: moving focus walks the whole accessibility
            // tree, so skip it for sessions that are only passed through.
            // (On a phone the keyboard would cover the conversation.)
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { focused = true }
        }
        #endif
        .onAppear {
            paste.onImages = { add($0) }
            paste.active = true
            paste.install()
            if let t = DebugHooks.env["BINARY_SEND_TEXT"] {
                // Debug: type a message and press return after the session loads.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { text = t; submit() }
            }
            if let paths = DebugHooks.env["BINARY_ATTACH"] {
                add(paths.split(separator: ",").compactMap { ImageProcessor.prepare(url: URL(fileURLWithPath: String($0))) })
            }
        }
        .onDisappear { paste.remove(); composingWatcher.remove() }
        .onAppear { composingWatcher.install { composing = focused && $0 } }
        .onChange(of: text) { _, _ in composing = focused && ComposingWatcher.composing() }
        .onChange(of: focused) { _, f in paste.active = f }
        // Unsent text survives switching sessions and restarts.
        .onAppear { text = ComposerDrafts.shared.text(for: controller.ref) }
        .onChange(of: text) { _, t in ComposerDrafts.shared.setText(t, for: controller.ref) }
    }

    /// One dim line: the other program can't pick up turns sent from here
    /// until the session is reopened there.
    private func heldHint(_ h: ExternalHold) -> String {
        if h.working {
            return tr("\(h.shortName) is working on a turn. What you send here waits and goes out when it finishes.").trimmingCharacters(in: .whitespaces)
        }
        switch h.holder {
        case "tmux", "terminal":
            return tr("Also open in \(h.shortName). Before continuing there, exit claude there and resume.")
        default:
            return tr("Also open in \(h.shortName). Before continuing there, close and reopen it there.")
        }
    }

    private func add(_ new: [PendingImage]) {
        let room = ImageProcessor.maxPerMessage - images.count
        images += new.prefix(max(room, 0))
        limitNotice = new.count > room
    }

    private var placeholder: String {
        if heldBusy, let h = hold { return tr("Message… sent when \(h.shortName) finishes this turn") }
        if busy { return tr("Claude is working — keep typing, messages queue up…") }
        if let s = summary, !s.live { return tr("Message Claude… (resumes the session)") }
        return tr("Message Claude…")
    }

    private func showEffortHUD(_ level: String) {
        hudSerial += 1
        let serial = hudSerial
        withAnimation(.easeOut(duration: 0.12)) { effortHUD = level }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            guard serial == hudSerial else { return }
            withAnimation(.easeIn(duration: 0.25)) { effortHUD = nil }
        }
    }

    private func submit() { submit(fork: false) }

    /// Sends (the server queues it while another program is mid-turn), or
    /// forks and continues in the fork.
    private func submit(fork: Bool) {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!msg.isEmpty || !images.isEmpty), !sending else { return }
        sending = true
        let sent = images
        text = ""
        images = []
        limitNotice = false
        Task {
            if fork {
                if let forked = await controller.fork(msg, images: sent.map(\.wire)) {
                    nav.selection = SessionRef(server: controller.conn.id, session: forked.id)
                } else {
                    text = msg
                    images = sent
                }
            } else {
                switch await controller.send(msg, images: sent.map(\.wire)) {
                case .sent:
                    break
                case .queued(let id):
                    drafts[id] = (msg, sent)
                    showQueued(QueuedMessage(id: id, text: String(msg.prefix(200)), images: sent.count))
                case .failed:
                    text = msg
                    images = sent
                }
            }
            sending = false
        }
    }

    private func showQueued(_ q: QueuedMessage) {
        justQueued.append(q)
        // By then the summary lists it, or it has been sent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { justQueued.removeAll { $0.id == q.id } }
    }

    private func cancel(_ q: QueuedMessage) {
        Task {
            if await controller.cancelQueued(q.id) { justQueued.removeAll { $0.id == q.id } }
            drafts[q.id] = nil
        }
    }

    /// Takes the message back into the box.
    private func edit(_ q: QueuedMessage) {
        guard let d = drafts[q.id] else { return }
        Task {
            guard await controller.cancelQueued(q.id) else { return }
            justQueued.removeAll { $0.id == q.id }
            drafts[q.id] = nil
            text = d.text
            images = d.images
            focused = true
        }
    }
}

/// A message waiting for the other program's turn to end.
private struct QueuedChip: View {
    let item: QueuedMessage
    let holder: String?
    var onEdit: (() -> Void)?
    var onCancel: () -> Void
    @Environment(\.theme) private var theme

    private var preview: String {
        let t = (item.text ?? "").replacingOccurrences(of: "\n", with: " ")
        if !t.isEmpty { return t }
        let n = item.images ?? 0
        return n == 1 ? tr("1 image") : tr("\(n) images")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .foregroundStyle(theme.c.textFaint)
            (Text(holder.map { tr("Waiting for \($0) to finish") } ?? tr("Waiting for the turn to finish"))
                .foregroundColor(theme.c.textMuted)
             + Text(" · " + preview).foregroundColor(theme.c.text))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .buttonStyle(.icon(size: 20))
                    .help(tr("Edit: take it back into the message box"))
            }
            Button(action: onCancel) { Image(systemName: "xmark") }
                .buttonStyle(.icon(size: 20))
                .help(tr("Don't send"))
        }
        .font(theme.font(.caption))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).fill(theme.c.surfaceAlt))
        .overlay(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous).strokeBorder(theme.c.border))
    }
}

/// Permission mode, model and effort, under the message box.
struct SessionControls: View {
    let controller: SessionController
    @Environment(\.theme) private var theme
    @Environment(AppearanceStore.self) private var appearance
    @Environment(Navigation.self) private var nav
    @State private var customModel = false
    @State private var customModelText = ""

    private var summary: SessionSummary? { controller.summary }
    private var info: ServerInfo? { controller.conn.info }

    /// How much the bar shows; it drops detail as the window narrows.
    private enum Density { case full, compact, icons }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(.full)
            bar(.compact)
            #if os(macOS)
            bar(.icons)
            #else
            // A phone keeps the names and scrolls instead.
            ScrollView(.horizontal) { bar(.compact) }
                .scrollIndicators(.never)
            #endif
        }
        .alert(tr("Custom Model"), isPresented: $customModel) {
            TextField(tr("Model ID or alias, e.g. claude-opus-5-5"), text: $customModelText)
            Button(tr("Cancel"), role: .cancel) {}
            Button(tr("Use")) { setModel(customModelText.trimmingCharacters(in: .whitespaces)) }
        }
    }

    private func bar(_ d: Density) -> some View {
        HStack(spacing: 4) {
            modeMenu(text: d != .icons)
            Spacer(minLength: 8)
            if let s = summary, s.shownState != .idle || s.live {
                let idle = s.shownState == .idle
                let bg = s.busyTasks.count
                let label = !idle ? s.statusText
                    : bg > 0 ? tr("\(bg) background task\(bg == 1 ? "" : "s")") : tr("Process idle")
                Button {
                    // The info panel's Process card says what's running.
                    #if os(macOS)
                    withAnimation(.easeOut(duration: 0.2)) { appearance.showInspector = true }
                    #else
                    nav.showingInfo = true
                    #endif
                } label: {
                    HStack(spacing: 4) {
                        StatusDot(state: s.shownState, live: s.live)
                        if d == .full { Text(label) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(theme.font(.caption))
                .foregroundStyle(idle ? (bg > 0 ? theme.c.textMuted : theme.c.textFaint) : s.shownState.color(theme))
                .padding(.trailing, 6)
                .help(label + " · " + tr("Show what the process is running"))
            }
            if d == .full, let c = Format.cost(summary?.costUsd) {
                Text(c)
                    .font(theme.font(.caption).monospacedDigit())
                    .foregroundStyle(theme.c.textFaint)
                    .help(tr("Session cost so far (list price)"))
                    .padding(.trailing, 4)
            }
            if d != .icons, let ctx = summary?.context {
                HStack(spacing: 5) {
                    Text(tr("Context")).foregroundStyle(theme.c.textFaint)
                    UsageBar(percent: ctx.percent, height: 4).frame(width: 44)
                    Text("\(Int(ctx.percent.rounded()))%")
                        .foregroundStyle(ctx.percent >= 80 ? theme.c.warning : theme.c.textMuted)
                }
                .font(theme.font(.caption).monospacedDigit())
                .help(tr("Context window: \(Format.context(ctx))"))
                .padding(.trailing, 4)
            }
            modelMenu(text: d != .icons)
            EffortButton(controller: controller, showText: d != .icons, onCustomModel: askCustomModel)
        }
        .lineLimit(1)
    }

    private func modeMenu(text showText: Bool) -> some View {
        let current = summary?.permissionMode ?? ""
        let modes = info?.permissionModes ?? Format.modeKeys
        let risky = current == "bypassPermissions"
        return Menu {
            Picker(tr("Permission Mode"), selection: Binding(get: { current }, set: { v in
                Task { await controller.update(SettingsUpdate(permissionMode: v)) }
            })) {
                ForEach(modes, id: \.self) { m in
                    Text(Format.mode(m)).tag(m)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ControlLabel(icon: risky ? "exclamationmark.shield" : "lock.shield", text: Format.mode(current),
                         showText: showText, tint: risky ? theme.c.warning : nil)
        }
        .plainMenu()
        .help(tr("Permission mode. Requests that need approval appear above the message box."))
    }

    private func modelMenu(text showText: Bool) -> some View {
        let model = Format.modelSetting(summary?.model, last: summary?.lastModel, info: info)
        return Menu {
            ModelMenuItems(controller: controller, onCustom: askCustomModel)
        } label: {
            ControlLabel(icon: "cpu", text: model.value, note: model.note, showText: showText)
        }
        .plainMenu()
        .help(tr("Model. Switches right away while the process runs."))
    }

    private func askCustomModel() {
        customModelText = summary?.model ?? ""
        customModel = true
    }

    private func setModel(_ v: String) {
        Task { await controller.update(SettingsUpdate(model: v)) }
    }
}

/// The model picker, shared by the controls bar and the effort panel.
struct ModelMenuItems: View {
    let controller: SessionController
    var onCustom: () -> Void

    var body: some View {
        let summary = controller.summary
        let info = controller.conn.info
        let current = summary?.model ?? ""
        let models = (info?.models ?? []).filter { $0.value != "default" }
        Picker(tr("Model"), selection: Binding(get: { current == "default" ? "" : current }, set: { v in
            Task { await controller.update(SettingsUpdate(model: v)) }
        })) {
            Text(Format.modelSetting(nil, last: summary?.lastModel, info: info).text).tag("")
            ForEach(models) { m in
                Text(m.displayName).tag(m.value)
            }
            if !current.isEmpty, current != "default", !models.contains(where: { $0.value == current }) {
                Text(current).tag(current)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button(tr("Custom…"), action: onCustom)
    }
}

extension View {
    /// A menu whose label is drawn exactly as written, without a bezel or tint.
    func plainMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

/// A compact menu label: icon, text, small chevron, hover highlight.
struct ControlLabel: View {
    let icon: String
    let text: String
    /// Dimmed text before `text`, e.g. "Default" in "Default · Medium".
    var note: String? = nil
    var showText = true
    var tint: Color? = nil
    @Environment(\.theme) private var theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: theme.size(.caption)))
            if showText {
                if let note {
                    Text(note + " ·").foregroundStyle(theme.c.textFaint)
                }
                Text(text)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.7)
        }
        .font(theme.font(.caption).weight(.medium))
        .foregroundStyle(tint ?? (hover ? theme.c.text : theme.c.textMuted))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: theme.controlRadius - 2, style: .continuous).fill(hover ? theme.c.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(showText ? "" : note.map { "\($0) · \(text)" } ?? text)
    }
}
