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
                    organizer.sync(with: store)
                    projects.sync(with: store)
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
            Button(tr("Find in Conversation…")) { nav.transcriptSearchRequest += 1 }
                .keyboardShortcut("f")
                .disabled(nav.selection == nil || nav.draft != nil)
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
