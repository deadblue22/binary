import SwiftUI

/// Development hooks for checking screens in the simulator without tapping,
/// set with `SIMCTL_CHILD_<name>=… xcrun simctl launch <device> <bundle id>`:
///   BINARY_SELECT=<session id>      open that session (on server BINARY_SELECT_SERVER, default 0)
///   BINARY_SELECT_AGENT=<agent id>  with BINARY_SELECT: open that subagent
///   BINARY_NEW_SESSION=1|child      open a new session (child: of BINARY_SELECT)
///   BINARY_INFO=1                   with BINARY_SELECT: open the session info sheet
///   BINARY_SETTINGS=1               open Settings
///   BINARY_SET_LANGUAGE=en|zh       switch the UI language
///   BINARY_NO_NOTIFICATIONS=1       don't ask for notification permission
///   BINARY_SERVER=<url> BINARY_TOKEN=<token>  add this server unless it is there
/// BINARY_SEND_TEXT, BINARY_EXPAND_TOOLS and BINARY_SCROLL_TOP work as on the Mac.
@MainActor
enum PhoneDebugHooks {
    static var env: [String: String] { DebugHooks.env }

    static func run(store: ServerStore, nav: Navigation, appearance: AppearanceStore) {
        if let l = env["BINARY_SET_LANGUAGE"].flatMap(AppLanguage.init(rawValue:)) {
            appearance.language = l
        }
        if let url = env["BINARY_SERVER"], let token = env["BINARY_TOKEN"], !store.servers.contains(where: { $0.url == url }) {
            store.add(ServerConfig(name: env["BINARY_SERVER_NAME"] ?? "", url: url, token: token))
        }
        let index = Int(env["BINARY_SELECT_SERVER"] ?? "") ?? 0
        guard store.servers.indices.contains(index) else { return }
        let server = store.servers[index].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let id = env["BINARY_SELECT"] {
                let ref = SessionRef(server: server, session: id)
                if env["BINARY_NEW_SESSION"] == "child" {
                    nav.newChildSession(of: ref)
                    return
                }
                nav.selection = SessionRef(server: server, session: id, agent: env["BINARY_SELECT_AGENT"])
                if env["BINARY_INFO"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nav.showingInfo = true }
                }
            } else if env["BINARY_NEW_SESSION"] == "1" {
                nav.newSession()
            }
        }
    }
}
