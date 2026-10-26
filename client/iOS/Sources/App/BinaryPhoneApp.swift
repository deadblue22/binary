import SwiftUI
import UIKit
import UserNotifications

@main
struct BinaryPhoneApp: App {
    @State private var store = ServerStore()
    @State private var nav = Navigation()
    @State private var appearance = AppearanceStore()
    @State private var organizer = SessionOrganizer()
    @State private var projects = ProjectStore()

    var body: some Scene {
        let _ = appearance.language
        WindowGroup {
            RootView()
                .environment(store)
                .environment(nav)
                .environment(organizer)
                .environment(projects)
                .themed(appearance)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear {
                    PhoneNotifier.shared.attach(store: store, nav: nav)
                    organizer.sync(with: store)
                    projects.sync(with: store)
                    PhoneDebugHooks.run(store: store, nav: nav, appearance: appearance)
                }
        }
    }
}

/// Keeps the live streams running for the short while iOS allows after the
/// app goes to the background, so a turn that ends then still notifies.
@MainActor
final class BackgroundGrace {
    static let shared = BackgroundGrace()
    private var task: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Live sessions") {
            // Called on the main thread when the time is up.
            MainActor.assumeIsolated { BackgroundGrace.shared.end() }
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

/// Posts a notification when a session needs approval, finishes or fails
/// while the app is in the background (as long as iOS keeps it running), and
/// keeps the app icon badge at the number of pending approvals.
@MainActor
final class PhoneNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PhoneNotifier()
    private weak var store: ServerStore?
    private weak var nav: Navigation?
    private var attached = false
    /// Set from the scene phase: notifications are only for when the app isn't in front.
    var active = true

    func attach(store: ServerStore, nav: Navigation) {
        self.store = store
        self.nav = nav
        guard !attached else { return }
        attached = true
        store.onTransition = { [weak self] conn, old, new in self?.transition(conn, old, new) }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard DebugHooks.env["BINARY_NO_NOTIFICATIONS"] != "1" else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func transition(_ conn: ServerConnection, _ old: SessionSummary?, _ new: SessionSummary) {
        updateBadge()
        guard let old, !active else { return }
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

    func updateBadge() {
        let total = store?.orderedConnections.reduce(0) { $0 + $1.pendingCount } ?? 0
        UNUserNotificationCenter.current().setBadgeCount(total)
    }

    // Completion-handler variants, not `async`: the async ones hand the
    // completion back to UIKit from a cooperative-pool thread, and UIKit
    // asserts it's on the main thread (opening a notification crashed).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let server = (info["server"] as? String).flatMap(UUID.init(uuidString:))
        let session = info["session"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let server, let session {
                    self.nav?.selection = SessionRef(server: server, session: session)
                }
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.banner, .sound]) }
    }
}
