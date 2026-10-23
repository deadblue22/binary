import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Development hooks driven by environment variables, used to check the UI
/// without screen recording:
///   BINARY_SELECT=<session id>     select that session on the first server
///   BINARY_SNAPSHOT=<file.png>     render the main window to a PNG
///   BINARY_SNAPSHOT_DELAY=<sec>    wait before rendering (default 4)
///   BINARY_SNAPSHOT_QUIT=1         quit after rendering
///   BINARY_SNAPSHOT_MODE=screen    capture what is actually on screen (works with the
///                                  split view, shows views that failed to redraw)
///   BINARY_SNAPSHOT_MODE=composite like screen, but one image of the main window with
///                                  its popovers and sheets on top
///   BINARY_NEW_SESSION=1|child     open the New Session sheet (child: of the selected session)
///   BINARY_SELECT_AGENT=<agent id> with BINARY_SELECT: open that subagent
///   BINARY_SELECT_SERVER=<n>       BINARY_SELECT applies to the n-th server (0-based)
///   BINARY_WINDOW=<w>x<h>          resize the main window
///   BINARY_SETTINGS=1              open the settings window (rendered too)
///   BINARY_FLAT=1                  sidebar without split-view vibrancy
///   BINARY_SCROLL_TOP=1            open transcripts at the top
///   BINARY_EXPAND_TOOLS=1          show tool cards expanded
///   BINARY_SET_LANGUAGE=en|zh      switch the UI language 2 s after launch
///   BINARY_TOGGLE_INSPECTOR=1      toggle the info panel 2.5 s after launch
///   BINARY_ATTACH=<a.png,b.jpg>    put these images in the composer
///   BINARY_SEND_TEXT=<text>        type this in the composer and press return
///   BINARY_KEYS=<steps>            after 3 s, feed the focused field steps split by "|":
///                                  ⇧↩, ↩, ⇥, ⌘[, ⌘], mark:<text> (input-method candidates), or text
///   BINARY_EFFORT_PANEL=1          open the effort panel 2.5 s after launch
///   BINARY_LOAD_OLDER=1            press "Load earlier messages" 2.5 s after a session opens
///   BINARY_PROJECT_PICKER=1        with BINARY_NEW_SESSION: open the project list
///   BINARY_EDIT_PROJECT=new|current with BINARY_NEW_SESSION: open the project editor
///   BINARY_PREVIEW=<path>          with BINARY_SELECT: preview that file (relative to its folder)
///   BINARY_MOVE=<id>=<group>       move a session into a group (PATCH tag) after 2 s
///   BINARY_TIMING=1                print how long opening a session takes
///   BINARY_SCROLL_BENCH=<pages>    load that many older pages, show every row, then scroll
///                                  the transcript and print the time each step takes
///   BINARY_SCROLL_BENCH_RANGE=<pt> with BINARY_SCROLL_BENCH: scroll only that far from the end
///   BINARY_LOG=1                   trace sidebar reveal and redirect steps on stderr
/// A text dump of client state (servers, menus, scroll views) is written next
/// to the snapshot as <file.png>.txt.
@MainActor
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment
    static let flatLayout = env["BINARY_FLAT"] == "1"
    static let scrollTop = env["BINARY_SCROLL_TOP"] == "1"
    static let expandTools = env["BINARY_EXPAND_TOOLS"] == "1"
    static let openSettings = env["BINARY_SETTINGS"] == "1"
    static let timing = env["BINARY_TIMING"] == "1"
    static var openStarted: Date?

    static func log(_ what: @autoclosure () -> String) {
        guard env["BINARY_LOG"] == "1" else { return }
        FileHandle.standardError.write(Data("log \(what())\n".utf8))
    }

    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func mark(_ what: String) {
        guard timing, let t = openStarted else { return }
        FileHandle.standardError.write(Data("timing \(what) \(Int(Date().timeIntervalSince(t) * 1000))ms\n".utf8))
    }

    #if os(macOS)
    static func run(store: ServerStore, nav: Navigation, appearance: AppearanceStore) {
        if env["BINARY_TOGGLE_INSPECTOR"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { appearance.showInspector.toggle() }
        }
        if let l = env["BINARY_SET_LANGUAGE"].flatMap(AppLanguage.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { appearance.language = l }
        }
        let index = Int(env["BINARY_SELECT_SERVER"] ?? "") ?? 0
        if let id = env["BINARY_SELECT"], store.servers.indices.contains(index) {
            let server = store.servers[index].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                nav.selection = SessionRef(server: server, session: id, agent: env["BINARY_SELECT_AGENT"])
            }
        }
        if let move = env["BINARY_MOVE"]?.split(separator: "=", maxSplits: 1).map(String.init), move.count == 2,
           store.servers.indices.contains(index) {
            let server = store.servers[index].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Task {
                    do { try await store.connection(server)?.setGroup([move[0]], move[1]) } catch { print("move failed: \(error)") }
                }
            }
        }
        if let keys = env["BINARY_KEYS"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for step in keys.split(separator: "|").map(String.init) {
                    feed(step)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        if let size = env["BINARY_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
                var f = w.frame
                f.origin.y += f.height - size[1]
                f.size = NSSize(width: size[0], height: size[1])
                w.setFrame(f, display: true)
            }
        }

        if env["BINARY_NEW_SESSION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nav.newSession() }
        } else if env["BINARY_NEW_SESSION"] == "child" {
            // A child of the session picked with BINARY_SELECT.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let s = nav.selection { nav.newChildSession(of: s) }
            }
        }
        if let path = env["BINARY_PREVIEW"] {
            // Preview a file of the session picked with BINARY_SELECT.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let s = nav.selection { nav.filePreview = FilePreviewRequest(server: s.server, session: s.session, path: path) }
            }
        }
        guard let out = env["BINARY_SNAPSHOT"] else { return }
        let delay = Double(env["BINARY_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            snapshot(to: out)
            try? dump(store: store, nav: nav).write(toFile: out + ".txt", atomically: true, encoding: .utf8)
            if env["BINARY_SNAPSHOT_QUIT"] == "1" {
                NSApp.terminate(nil)
                // An open popover or sheet can refuse a normal quit; this is a test run.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
            }
        }
    }

    /// BINARY_SCROLL_BENCH: scrolls the tallest scroll view of the main window
    /// 40 pt per 120 Hz tick, to the top and back (or within
    /// BINARY_SCROLL_BENCH_RANGE of the end, three times), and prints the main
    /// thread's CPU time per step: scrolling, layout and display.
    static func scrollBench() {
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews)
        }
        guard let root = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let sv = scrollViews(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = sv.documentView else { return err("bench: no scroll view") }
        let maxY = doc.frame.height - sv.contentView.bounds.height
        let flipped = doc.isFlipped
        let range = Double(env["BINARY_SCROLL_BENCH_RANGE"] ?? "").map { CGFloat($0) }
        let lo: CGFloat = range.map { flipped ? max(0, maxY - $0) : 0 } ?? 0
        let hi: CGFloat = range.map { flipped ? maxY : min(maxY, $0) } ?? maxY
        var laps = range == nil ? 1 : 3
        var y = flipped ? maxY : 0
        var up = true
        var work: [Double] = []
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
        var views = 0
        func count(_ v: NSView) { views += 1; v.subviews.forEach(count) }
        count(doc)
        err("bench: content \(Int(doc.frame.height))pt, \(views) views")
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { t in
            MainActor.assumeIsolated {
                let toward: CGFloat = flipped == up ? -40 : 40
                y += toward
                if y < lo || y > hi {
                    y = min(max(y, lo), hi)
                    if up {
                        up = false
                    } else {
                        laps -= 1
                        up = true
                    }
                    if laps == 0 {
                        t.invalidate()
                        let w = work.sorted()
                        err(String(format: "bench: %d steps, ms per step avg %.2f p50 %.2f p95 %.2f max %.1f, over 8 ms %d",
                                   w.count, w.reduce(0, +) / Double(w.count), w[w.count / 2], w[w.count * 95 / 100],
                                   w.last ?? 0, w.filter { $0 > 8 }.count))
                        if env["BINARY_SNAPSHOT_QUIT"] == "1" { exit(0) }
                        return
                    }
                }
                let t0 = cpu()
                sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                sv.reflectScrolledClipView(sv.contentView)
                sv.window?.layoutIfNeeded()
                sv.window?.displayIfNeeded()
                CATransaction.flush()
                work.append(cpu() - t0)
            }
        }
    }

    /// One BINARY_KEYS step. Keys go through the event queue (and so through
    /// local monitors); text and candidates go straight to the field editor.
    static func feed(_ step: String) {
        // The frontmost window: a sheet when one is open.
        guard let w = NSApp.orderedWindows.first(where: \.isVisible) else { return }
        func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        switch step {
        case "⇧↩": return key("\r", 36, .shift)
        case "↩": return key("\r", 36)
        case "⇥": return key("\t", 48)
        case "⌘[": return key("[", 33, .command)
        case "⌘]": return key("]", 30, .command)
        default: break
        }
        guard let editor = w.firstResponder as? NSTextView else {
            log("keys: no focused text field for \(step)")
            return
        }
        let none = NSRange(location: NSNotFound, length: 0)
        switch step {
        case let s where s.hasPrefix("mark:"):
            let t = String(s.dropFirst(5))
            editor.setMarkedText(t, selectedRange: NSRange(location: t.utf16.count, length: 0), replacementRange: none)
        default:
            editor.insertText(step, replacementRange: none)
        }
    }

    /// BINARY_SNAPSHOT_MODE=screen: capture what the window server actually
    /// shows for our own window (no forced redraw), via CGWindowListCreateImage
    /// looked up at runtime since the SDK marks it unavailable.
    static func screenImage(_ window: NSWindow) -> Data? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        guard let img = fn(.null, 1 << 3, UInt32(window.windowNumber), 1 | (1 << 3))?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    /// BINARY_SNAPSHOT_MODE=composite: our windows over the main window's
    /// area, in one image, via CGWindowListCreateImageFromArray.
    static func compositeImage() -> Data? {
        typealias Fn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        // orderedWindows leaves out popovers, so take every visible window
        // and put the main one at the back.
        let visible = NSApp.windows.filter { $0.isVisible }
        guard let main = NSApp.orderedWindows.last(where: { $0.isVisible && !$0.isSheet }) ?? visible.first,
              let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImageFromArray") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let windows = visible.filter { $0 != main } + [main]
        // Front to back; the array holds window ids, not objects.
        var ids: [UnsafeRawPointer?] = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
        // Global display coordinates have their origin at the top left.
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let f = main.frame
        let rect = CGRect(x: f.minX, y: screenH - f.maxY, width: f.width, height: f.height)
        guard let img = fn(rect, array, 1 | (1 << 3))?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func snapshot(to path: String) {
        if env["BINARY_SNAPSHOT_MODE"] == "composite" {
            if let data = compositeImage() { try? data.write(to: URL(fileURLWithPath: path)) }
            return
        }
        if env["BINARY_SNAPSHOT_MODE"] == "screen" {
            for (i, w) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
                guard let data = screenImage(w) else { continue }
                let file = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
                try? data.write(to: URL(fileURLWithPath: file))
            }
            return
        }
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        for (i, window) in windows.enumerated() {
            // Sheets are separate windows; render each next to the main one.
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            guard let data = render(view) else { continue }
            let file = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
            try? data.write(to: URL(fileURLWithPath: file))
        }
    }

    static func render(_ view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// A text dump of client state, written next to the snapshot.
    static func dump(store: ServerStore, nav: Navigation) -> String {
        var lines: [String] = []
        for c in store.orderedConnections {
            lines.append("server \(c.displayName) status=\(c.status) sessions=\(c.sessions.count)")
            for s in c.sessions.values.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(8) {
                lines.append("  \(s.state) \(s.live ? "live" : "-") \(s.title.prefix(50))")
            }
        }
        lines.append("selection=\(String(describing: nav.selection))")
        if let editor = NSApp.orderedWindows.first(where: \.isVisible)?.firstResponder as? NSTextView {
            lines.append("focused text=\(editor.string.debugDescription) marked=\(editor.hasMarkedText())")
        }
        let mirrors = MirrorIndex(store.orderedConnections)
        for c in store.orderedConnections {
            lines.append("mirrors hidden on \(c.displayName): \(mirrors.hidden(on: c.id).count), parents carried to it: \(mirrors.parents[c.id]?.count ?? 0)")
        }
        // Rough timings of the work redone on every update.
        func ms(_ n: Int, _ f: () -> Void) -> String {
            let t = Date()
            for _ in 0..<n { f() }
            return String(format: "%.2fms", Date().timeIntervalSince(t) * 1000 / Double(n))
        }
        let org = SessionOrganizer()
        for c in store.orderedConnections {
            lines.append("timing \(c.displayName) n=\(c.sessions.count) build=\(ms(20) { _ = SidebarBuilder.build(c, org: org, query: "") })")
        }
        if let menu = NSApp.mainMenu {
            lines.append("menus: " + menu.items.map { $0.title }.joined(separator: " | "))
            // Two menu items on the same shortcut.
            var seen: [String: String] = [:]
            func walk(_ m: NSMenu) {
                for item in m.items {
                    if let sub = item.submenu { walk(sub) }
                    guard !item.keyEquivalent.isEmpty else { continue }
                    let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
                    if let other = seen[key] { lines.append("shortcut clash: \(other) / \(item.title) (\(item.keyEquivalent))") }
                    seen[key] = item.title
                }
            }
            walk(menu)
            if let session = menu.items.first(where: { $0.title == "Session" })?.submenu {
                lines.append("session menu: " + session.items.map { $0.title + ($0.isEnabled ? "" : " (off)") }.joined(separator: " | "))
            }
        }
        // Selectable text runs: each FlowTextView holds a message's paragraphs and lists.
        func textViews(_ v: NSView) -> [FlowTextView] {
            ((v as? FlowTextView).map { [$0] } ?? []) + v.subviews.flatMap(textViews)
        }
        if let root = NSApp.windows.first(where: { $0.isVisible })?.contentView {
            let tvs = textViews(root)
            let paras = tvs.map { $0.string.components(separatedBy: "\n").count }
            lines.append("flowText views=\(tvs.count) maxParagraphsInOne=\(paras.max() ?? 0)")
            for tv in tvs.prefix(6) {
                let used = tv.layoutManager.map { $0.usedRect(for: tv.textContainer!) } ?? .zero
                let docY: Int = {
                    guard let sv = tv.enclosingScrollView, let doc = sv.documentView else { return -1 }
                    return Int(tv.convert(NSPoint.zero, to: doc).y)
                }()
                lines.append("  flow docY=\(docY) frame=\(Int(tv.frame.width))x\(Int(tv.frame.height)) super=\(Int(tv.superview?.frame.width ?? -1))x\(Int(tv.superview?.frame.height ?? -1)) container=\(Int(tv.textContainer?.size.width ?? -1)) used=\(Int(used.width))x\(Int(used.height)) chars=\(tv.string.count)")
            }
        }
        // Scroller styles, to check that no wide legacy scrollers remain.
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews)
        }
        for w in NSApp.windows where w.isVisible {
            guard let root = w.contentView?.superview ?? w.contentView else { continue }
            let all = scrollViews(root)
            let legacy = all.filter { $0.scrollerStyle == .legacy }
            lines.append("window size=\(Int(w.frame.width))x\(Int(w.frame.height)) min=\(Int(w.minSize.width)) title=\(w.title)")
            lines.append("window \(w.title): scrollViews=\(all.count) legacy=\(legacy.count) system=\(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay")")
            for sv in all.prefix(8) {
                let origin = sv.convert(NSPoint.zero, to: nil)
                lines.append("  scroll x=\(Int(origin.x)) frame=\(Int(sv.frame.width)) clip=\(Int(sv.contentView.frame.width)) doc=\(Int(sv.documentView?.frame.width ?? -1)) offsetX=\(Int(sv.contentView.bounds.origin.x)) visible=\(Int(sv.visibleRect.width)) | docH=\(Int(sv.documentView?.frame.height ?? -1)) offsetY=\(Int(sv.contentView.bounds.origin.y)) viewH=\(Int(sv.contentView.bounds.height)) subviews=\(sv.documentView?.subviews.count ?? -1)")
            }
        }
        return lines.joined(separator: "\n")
    }
    #endif
}
