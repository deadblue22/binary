import AppKit
import SwiftUI
import UserNotifications

@main
struct BinaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ServerStore()
    @State private var nav = Navigation()
    @State private var appearance = AppearanceStore()
    @State private var organizer = SessionOrganizer()
    @State private var projects = ProjectStore()

    var body: some Scene {
        let _ = appearance.language
        WindowGroup("Binary", id: "main") {
            ContentView()
                .environment(store)
                .environment(nav)
                .environment(organizer)
                .environment(projects)
                .themed(appearance)
                .frame(minWidth: InspectorLayout.windowMinWidth(inspector: appearance.showInspector), minHeight: 560)
                .onAppear {
                    appearance.apply()
                    Notifier.shared.attach(store: store, nav: nav)
                    DebugHooks.run(store: store, nav: nav, appearance: appearance)
                }
        }
        .commands { AppCommands(nav: nav, appearance: appearance, lang: appearance.language) }
        Settings {
            SettingsView()
                .environment(store)
                .themed(appearance)
        }
    }
}

/// Menu bar commands. Reads the language so the menus follow a switch.
struct AppCommands: Commands {
    let nav: Navigation
    let appearance: AppearanceStore
    let lang: AppLanguage

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("New Session")) { nav.newSession() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button(tr("Bigger Text")) { appearance.biggerText() }
                .keyboardShortcut("+")
                .disabled(appearance.fontSize == FontSizeLevel.allCases.last)
            Button(tr("Smaller Text")) { appearance.smallerText() }
                .keyboardShortcut("-")
                .disabled(appearance.fontSize == FontSizeLevel.allCases.first)
            Button(tr("Default Text Size")) { appearance.resetText() }
                .keyboardShortcut("0")
            Divider()
        }
        CommandMenu("Session") {
            Button(tr("Search Sessions")) { nav.searchRequest += 1 }
                .keyboardShortcut("k")
            Divider()
            Button(tr("Previous")) { nav.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(tr("Next")) { nav.step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Button(tr("Lower Effort")) { nav.stepEffort(-1) }
                .keyboardShortcut("[")
            Button(tr("Raise Effort")) { nav.stepEffort(1) }
                .keyboardShortcut("]")
        }
    }
}

struct NewSessionDraft: Equatable {
    var serial: Int
    var parent: SessionRef?
    var group: String?
    var template: SessionRef?
}

@MainActor
@Observable
final class Navigation {
    var selection: SessionRef?
    /// A new session being set up in the detail column; it becomes a real
    /// session when its first message is sent.
    var draft: NewSessionDraft?
    /// A file a message links to, shown in the preview sheet.
    var filePreview: FilePreviewRequest?

    /// Opens a blank session: in `group`, starting from `template`'s folder
    /// (a group's +), or as a child of `parent`.
    func newSession(parent: SessionRef? = nil, group: String? = nil, template: SessionRef? = nil) {
        draft = NewSessionDraft(serial: (draft?.serial ?? 0) + 1, parent: parent?.sessionOnly, group: group, template: template)
        selection = nil
    }

    func newChildSession(of parent: SessionRef) { newSession(parent: parent) }
    /// Sidebar rows in display order, kept current by the sidebar. Not
    /// observed: nothing draws from it.
    @ObservationIgnored var visibleOrder: [SessionRef] = []
    /// Bumped to focus the sidebar search field.
    var searchRequest = 0
    /// Set by the sidebar; scrolls a row into view without a state change
    /// (a state round-trip here cost a second full sidebar update per click).
    @ObservationIgnored var scrollHandler: ((SessionRef) -> Void)?

    func scroll(to ref: SessionRef) { scrollHandler?(ref) }

    /// ⌘[ / ⌘]: bumped for the open session's composer to act on (nothing
    /// happens while no message box is shown).
    struct EffortStep: Equatable {
        var delta = 0
        var serial = 0
    }
    var effortStep = EffortStep()

    func stepEffort(_ d: Int) {
        effortStep = EffortStep(delta: d, serial: effortStep.serial + 1)
    }

    /// Moves the selection up or down the sidebar.
    func step(_ d: Int) {
        guard !visibleOrder.isEmpty else { return }
        let i = selection.flatMap { visibleOrder.firstIndex(of: $0) } ?? (d > 0 ? -1 : visibleOrder.count)
        let next = visibleOrder[max(0, min(visibleOrder.count - 1, i + d))]
        selection = next
        scroll(to: next)
    }
}

extension View {
    /// Injects the appearance store, the resolved theme and its tint.
    func themed(_ appearance: AppearanceStore) -> some View {
        modifier(ThemedRoot(appearance: appearance))
    }
}

private struct ThemedRoot: ViewModifier {
    let appearance: AppearanceStore

    func body(content: Content) -> some View {
        let theme = appearance.theme
        content
            .environment(appearance)
            .environment(\.theme, theme)
            .tint(theme.c.focus)
            .font(theme.font(.body))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if DebugHooks.env["BINARY_SNAPSHOT"] != nil {
            // Snapshot runs stay in the background so they don't take the keyboard.
            NSApp.setActivationPolicy(.accessory)
            return
        }
        // Needed when launched as a bare executable (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Saved transcripts and session lists still waiting out their pause.
        LocalCache.shared.flushAll()
        ComposerDrafts.shared.save()
    }
}

/// Posts macOS notifications when a session needs approval or finishes while
/// the app is in the background, and keeps the dock badge at the number of
/// pending approvals.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private weak var store: ServerStore?
    private weak var nav: Navigation?
    private var attached = false

    /// UNUserNotificationCenter crashes outside an app bundle.
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func attach(store: ServerStore, nav: Navigation) {
        self.store = store
        self.nav = nav
        guard !attached else { return }
        attached = true
        store.onTransition = { [weak self] conn, old, new in self?.transition(conn, old, new) }
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func transition(_ conn: ServerConnection, _ old: SessionSummary?, _ new: SessionSummary) {
        updateBadge()
        guard let old, available, !NSApp.isActive else { return }
        if new.pending > old.pending {
            post(conn, new, title: tr("Needs approval"), body: new.activity ?? new.title)
        } else if old.status.isBusy && new.status == .idle && new.live {
            post(conn, new, title: tr("Finished"), body: new.lastSummary ?? new.preview ?? new.title)
        } else if new.status == .error && old.status != .error {
            post(conn, new, title: tr("Error"), body: new.error ?? new.title)
        }
    }

    private func post(_ conn: ServerConnection, _ s: SessionSummary, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(title) · \(s.title)"
        content.subtitle = "\(conn.displayName) · \(s.project)"
        content.body = body
        content.sound = .default
        content.userInfo = ["server": conn.id.uuidString, "session": s.id]
        let req = UNNotificationRequest(identifier: "\(s.id)-\(title)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func updateBadge() {
        let total = store?.orderedConnections.reduce(0) { $0 + $1.pendingCount } ?? 0
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let server = (info["server"] as? String).flatMap(UUID.init(uuidString:)),
              let session = info["session"] as? String else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            self.nav?.selection = SessionRef(server: server, session: session)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
