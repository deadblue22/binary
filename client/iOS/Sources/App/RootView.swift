import SwiftUI

/// A screen pushed over the session list.
enum Route: Hashable {
    case session(SessionRef)
    /// A subagent, pushed over its parent session.
    case subagent(SessionRef)
    case newSession(Int)
}

/// The session list with the open session pushed over it. The stack is worked
/// out from `Navigation` (selection and draft), which is what the shared views
/// change: Task cards open subagents, the info panel opens child sessions,
/// notifications open the session they're about.
struct RootView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Navigation.self) private var nav
    @Environment(SessionOrganizer.self) private var org
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var phase
    @State private var open = OpenSessions()
    @State private var backgrounded = false

    private var controller: SessionController? {
        get { open.controller }
        nonmutating set { open.controller = newValue }
    }
    private var agent: SubagentController? {
        get { open.agent }
        nonmutating set { open.agent = newValue }
    }

    var body: some View {
        @Bindable var nav = nav
        NavigationStack(path: path) {
            SessionListView()
                .navigationDestination(for: Route.self) { RouteScreen(route: $0, open: open) }
        }
        .tint(theme.c.focus)
        .sheet(item: $nav.filePreview) { FilePreviewView(request: $0) }
        .onChange(of: nav.selection, initial: true) { _, ref in select(ref) }
        .onChange(of: nav.draft) { _, d in if d != nil { nav.showingInfo = false } }
        .onChange(of: theme.lang) { _, _ in reconnect() }
        .onChange(of: phase) { _, p in phaseChanged(p) }
    }

    private var path: Binding<[Route]> {
        Binding(get: {
            if let d = nav.draft { return [.newSession(d.serial)] }
            guard let s = nav.selection else { return [] }
            return s.agent == nil ? [.session(s)] : [.session(s.sessionOnly), .subagent(s)]
        }, set: { routes in
            switch routes.last {
            case nil:
                nav.draft = nil
                nav.selection = nil
            case .session(let r)?, .subagent(let r)?:
                nav.draft = nil
                nav.selection = r
            case .newSession?:
                break
            }
        })
    }

    /// Keeps a live controller for the open session, and for the subagent
    /// pushed over it. Going back stops a controller's stream but keeps it:
    /// the screen sliding away still shows it (dropping it would turn that
    /// screen into a spinner mid-animation), and opening it again resumes.
    private func select(_ ref: SessionRef?) {
        if ref != nil { nav.draft = nil }
        nav.showingInfo = false
        // A hidden copy of a session another server runs: open that one.
        if let ref, !org.showMirrors, let live = MirrorIndex(store.orderedConnections).redirect(ref) {
            nav.selection = live
            return
        }
        if let session = ref?.sessionOnly {
            if controller?.ref == session {
                controller?.start()
            } else {
                controller?.stop()
                controller = nil
                if let conn = store.connection(session.server) {
                    let c = SessionController(conn: conn, id: session.session)
                    c.start()
                    controller = c
                }
            }
        } else {
            controller?.stop()
        }
        if let ref, let id = ref.agent {
            if agent?.ref == ref {
                agent?.start()
            } else {
                agent?.stop()
                agent = nil
                if let conn = store.connection(ref.server) {
                    let a = SubagentController(conn: conn, sessionID: ref.session, agentID: id)
                    a.start()
                    agent = a
                }
            }
        } else {
            agent?.stop()
        }
    }

    /// Opens every stream again: after a language switch (the server words
    /// activity in the language a stream was opened with) or coming back
    /// from the background (iOS cut the connections).
    private func reconnect() {
        for c in store.orderedConnections { c.reconnect() }
        if nav.selection != nil {
            controller?.stop()
            controller?.start()
        }
        if nav.selection?.agent != nil {
            agent?.stop()
            agent?.start()
        }
    }

    private func phaseChanged(_ p: ScenePhase) {
        PhoneNotifier.shared.active = p == .active
        switch p {
        case .background:
            LocalCache.shared.flushAll()
            ComposerDrafts.shared.save()
            BackgroundGrace.shared.begin()
            backgrounded = true
        case .active:
            BackgroundGrace.shared.end()
            PhoneNotifier.shared.updateBadge()
            if backgrounded {
                backgrounded = false
                reconnect()
            }
        default:
            break
        }
    }
}

/// The live controllers of what is open: the session, and a subagent pushed
/// over it. An object, so the pushed screens observe it (a destination
/// closure doesn't pick up changes to the root's own state).
@MainActor
@Observable
final class OpenSessions {
    var controller: SessionController?
    var agent: SubagentController?
}

/// One pushed screen.
private struct RouteScreen: View {
    let route: Route
    let open: OpenSessions
    @Environment(Navigation.self) private var nav

    var body: some View {
        switch route {
        case .session(let ref):
            if let c = open.controller, c.ref == ref {
                PhoneSessionView(controller: c).id(ref)
            } else {
                LoadingView()
            }
        case .subagent(let ref):
            if let a = open.agent, a.ref == ref {
                PhoneSubagentView(controller: a).id(ref)
            } else {
                LoadingView()
            }
        case .newSession(let serial):
            if let draft = nav.draft, draft.serial == serial {
                NewSessionView(draft: draft).id(serial)
            } else {
                LoadingView()
            }
        }
    }
}
