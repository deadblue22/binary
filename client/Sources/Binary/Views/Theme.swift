import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Settings

enum ThemeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Binary's own look: cool slate grays with an indigo accent.
    case binary
    /// Colors and type parameters after the Primary theme for Obsidian
    /// (github.com/primary-theme/obsidian): warm parchment, tactile controls.
    case primary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .binary: return "Binary"
        case .primary: return "Primary"
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return tr("System")
        case .light: return tr("Light")
        case .dark: return tr("Dark")
        }
    }
}

enum FontSizeLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large, xlarge
    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return tr("Small")
        case .medium: return tr("Medium")
        case .large: return tr("Large")
        case .xlarge: return tr("Extra Large")
        }
    }

    /// Body text size in points; `medium` is the default.
    var base: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 14.5
        case .large: return 16
        case .xlarge: return 18
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case en, zh
    var id: String { rawValue }
    /// Each language by its own name ("Chinese" written in Chinese).
    var label: String { self == .en ? "English" : "\u{4E2D}\u{6587}" }
}

/// The UI language. Strings are written inline in English as `tr("…")`;
/// other languages come from a table keyed by that text (Resources/zh-Hans.json).
enum L10n {
    static var lang: AppLanguage = .en

    /// English text to Chinese. Values in a string are written {0}, {1}, …
    /// in both the key and the translation, so a translation can reorder them.
    static let zh: [String: String] = {
        let bundled = Bundle.main.url(forResource: "zh-Hans", withExtension: "json")
        // `swift run` has no app bundle: read it from the source tree.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../Resources/zh-Hans.json").standardizedFileURL
        guard let data = (bundled.flatMap { try? Data(contentsOf: $0) }) ?? (try? Data(contentsOf: source)),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }()
}

/// UI text: the English literal, with its interpolated values kept apart so
/// a translation can place them.
struct Phrase: ExpressibleByStringInterpolation {
    var key = ""
    var values: [String] = []

    init(stringLiteral value: String) { key = value }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        values = stringInterpolation.values
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var values: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(values.count)}"
            values.append(String(describing: value))
        }
    }

    /// Puts the values into `template`. In Chinese text a Latin word gets a
    /// space where it meets a Chinese character.
    func fill(_ template: String, spaced: Bool) -> String {
        guard !values.isEmpty else { return template }
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}"),
              let i = Int(rest[rest.index(after: open)..<close]), values.indices.contains(i) {
            out += rest[..<open]
            var v = values[i]
            if spaced {
                if let a = out.last, isWide(a), let b = v.first, isLatin(b) { v = " " + v }
                let next = rest[rest.index(after: close)...].first
                if let a = v.last, isLatin(a), let b = next, isWide(b) { v += " " }
            }
            out += v
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    private func isLatin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
    private func isWide(_ c: Character) -> Bool { c.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false }
}

func tr(_ p: Phrase) -> String {
    if L10n.lang == .zh, let t = L10n.zh[p.key] { return p.fill(t, spaced: true) }
    return p.fill(p.key, spaced: false)
}

/// Theme, light/dark, text size and language, persisted to appearance.json
/// next to servers.json.
@MainActor
@Observable
final class AppearanceStore {
    var style: ThemeStyle = .binary { didSet { changed() } }
    var mode: AppearanceMode = .system { didSet { changed(); if !loading { apply() } } }
    var fontSize: FontSizeLevel = .medium { didSet { changed() } }
    var language: AppLanguage = .en { didSet { L10n.lang = language; changed() } }
    /// Whether the session info panel on the right is open.
    var showInspector = true { didSet { changed() } }

    @ObservationIgnored private var loading = false
    private let fileURL = ClientFiles.url("appearance.json")

    private struct Stored: Codable {
        var style: ThemeStyle?
        var mode: AppearanceMode?
        var fontSize: FontSizeLevel?
        var language: AppLanguage?
        var inspector: Bool?
    }

    init() {
        loading = true
        if let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            style = s.style ?? .binary
            mode = s.mode ?? .system
            fontSize = s.fontSize ?? .medium
            language = s.language ?? .en
            showInspector = s.inspector ?? true
        }
        L10n.lang = language
        loading = false
    }

    var theme: Theme { Theme(style: style, size: fontSize, lang: language) }

    /// Applies the light/dark choice to every window, menu and alert.
    func apply() {
        #if os(macOS)
        guard let app = NSApp else { return }
        switch mode {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
    }

    /// The light/dark choice for `preferredColorScheme` (iOS has no app-wide appearance).
    var colorScheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func biggerText() { step(1) }
    func smallerText() { step(-1) }
    func resetText() { fontSize = .medium }

    private func step(_ d: Int) {
        let all = FontSizeLevel.allCases
        guard let i = all.firstIndex(of: fontSize) else { return }
        fontSize = all[max(0, min(all.count - 1, i + d))]
    }

    private func changed() {
        guard !loading else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = Stored(style: style, mode: mode, fontSize: fontSize, language: language, inspector: showInspector)
        guard let data = try? enc.encode(stored) else { return }
        ClientFiles.write(data, to: fileURL)
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

/// The client's config directory (~/Library/Application Support/Binary, or
/// BINARY_CLIENT_DIR for testing).
enum ClientFiles {
    static let directory: URL = {
        if let dir = ProcessInfo.processInfo.environment["BINARY_CLIENT_DIR"] {
            return URL(fileURLWithPath: dir)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Binary", isDirectory: true)
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func write(_ data: Data, to url: URL, private isPrivate: Bool = false) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        if isPrivate {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Theme

/// Resolved theme: colors (which adapt to light/dark on their own), shape and
/// type scale. Read it with `@Environment(\.theme)`.
struct Theme: Equatable, Sendable {
    let style: ThemeStyle
    let size: FontSizeLevel
    /// Part of the theme so that views re-render when the language changes.
    let lang: AppLanguage
    let c: Palette

    init(style: ThemeStyle, size: FontSizeLevel, lang: AppLanguage = L10n.lang) {
        self.style = style
        self.size = size
        self.lang = lang
        self.c = style == .primary ? .primary : .binary
    }

    static func == (a: Theme, b: Theme) -> Bool { a.style == b.style && a.size == b.size && a.lang == b.lang }

    var isPrimary: Bool { style == .primary }

    // Shape
    var cardRadius: CGFloat { isPrimary ? 8 : 12 }
    var controlRadius: CGFloat { 8 }
    var rowRadius: CGFloat { isPrimary ? 6 : 8 }
    var bubbleRadius: CGFloat { isPrimary ? 10 : 16 }
    /// Primary's buttons and inputs have a raised bottom edge.
    var tactile: Bool { isPrimary }

    // Type scale
    var base: CGFloat { size.base }
    var scale: CGFloat { base / 13 }
    var lineSpacing: CGFloat { (base * 0.42).rounded() }
    var monoLineSpacing: CGFloat { (base * 0.22).rounded() }
    /// Reading width of the transcript column.
    var readingWidth: CGFloat { 860 * min(scale, 1.25) }
    /// Side margin of the transcript and the message box; a phone has no room to spare.
    #if os(macOS)
    var gutter: CGFloat { 28 }
    #else
    var gutter: CGFloat { 14 }
    #endif
    /// The round send / stop buttons in the message box (bigger for a finger).
    #if os(macOS)
    var sendButton: CGFloat { 28 }
    #else
    var sendButton: CGFloat { 32 }
    #endif

    func size(_ r: TextRole) -> CGFloat {
        switch r {
        case .body: return base
        case .callout: return base - 1
        case .caption: return max(10.5, base - 2.5)
        case .small: return max(10, base - 3.5)
        case .headline: return base + 1
        case .title: return base + 5
        case .h1: return (base * 1.55).rounded()
        case .h2: return (base * 1.32).rounded()
        case .h3: return (base * 1.15).rounded()
        case .h4: return base + 0.5
        case .mono: return base - 1.5
        case .monoSmall: return max(10.5, base - 2.5)
        case .rowTitle: return base - 0.5
        case .rowMeta: return max(10.5, base - 2.5)
        }
    }

    func font(_ r: TextRole) -> Font {
        let s = size(r)
        switch r {
        case .mono, .monoSmall:
            return mono(s)
        case .headline:
            return text(s).weight(.semibold)
        case .title, .h1, .h2, .h3, .h4:
            return text(s).weight(isPrimary ? .semibold : .bold)
        default:
            return text(s)
        }
    }

    func text(_ size: CGFloat) -> Font {
        if isPrimary, Fonts.inter { return .custom("Inter", size: size) }
        return .system(size: size)
    }

    func mono(_ size: CGFloat) -> Font {
        if isPrimary, let name = Fonts.cascadia { return .custom(name, size: size) }
        return .system(size: size, design: .monospaced)
    }
}

enum TextRole {
    case body, callout, caption, small, headline, title
    case h1, h2, h3, h4
    case mono, monoSmall
    case rowTitle, rowMeta
}

/// Primary's typefaces, used when they are installed.
enum Fonts {
    #if os(macOS)
    static let families = Set(NSFontManager.shared.availableFontFamilies)
    #else
    static let families = Set(UIFont.familyNames)
    #endif
    static let inter = families.contains("Inter")
    static let cascadia: String? = ["Cascadia Code", "Cascadia Mono"].first { families.contains($0) }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(style: .binary, size: .medium, lang: .en)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Palettes

struct Palette: Sendable {
    // Surfaces
    var background: Color      // transcript / detail
    var sidebar: Color
    var surface: Color         // cards
    var surfaceAlt: Color      // card headers, recessed areas
    var border: Color
    var borderStrong: Color
    var hover: Color
    var selection: Color       // selected sidebar row
    var selectionText: Color
    var input: Color

    // Text
    var text: Color
    var textMuted: Color
    var textFaint: Color
    var heading: Color

    // Accent
    var accent: Color          // filled buttons
    var accentHover: Color
    var onAccent: Color
    var focus: Color           // focus rings, tint

    // Messages and content
    var userBubble: Color
    var userBubbleBorder: Color
    var userText: Color
    var code: Color
    var codeHeader: Color
    var inlineCode: Color
    var inlineCodeBackground: Color
    var link: Color
    var quoteBar: Color
    var quoteBackground: Color
    var tableHeader: Color
    var tableRow: Color
    var tableRowAlt: Color
    var listMarker: Color
    var tag: Color

    // Status
    var success: Color
    var warning: Color
    var danger: Color
    var running: Color
    var external: Color

    var shadow: Color
}

extension Palette {
    static let binary = Palette(
        background: .dyn(0xF7F8FA, 0x16181D),
        sidebar: .dyn(0xEEF0F4, 0x111317),
        surface: .dyn(0xFFFFFF, 0x1D2026),
        surfaceAlt: .dyn(0xF3F5F8, 0x22252C),
        border: .dyn(0xE2E5EB, 0x2B2F38),
        borderStrong: .dyn(0xCDD2DB, 0x3A3F4B),
        hover: .dyn(0xE3E6EC, 0x1C1F25),
        selection: .dyn(0xDFDFFA, 0x292B4A),
        selectionText: .dyn(0x2B2C9A, 0xDADBFF),
        input: .dyn(0xFFFFFF, 0x1D2026),
        text: .dyn(0x1B1F2A, 0xE3E6EC),
        textMuted: .dyn(0x586072, 0x9DA4B1),
        textFaint: .dyn(0x8D94A3, 0x6C7383),
        heading: .dyn(0x10131B, 0xF4F5F8),
        accent: .dyn(0x5A5BE0, 0x8183F7),
        accentHover: .dyn(0x4A4BCC, 0x9395FA),
        onAccent: .dyn(0xFFFFFF, 0x0E0F16),
        focus: .dyn(0x5A5BE0, 0x8F91F8),
        userBubble: .dyn(0xE9E9FC, 0x252842),
        userBubbleBorder: .dyn(0xD9D9F6, 0x313457),
        userText: .dyn(0x1B1F2A, 0xE6E7F2),
        code: .dyn(0xF3F4F8, 0x101216),
        codeHeader: .dyn(0xEAECF2, 0x171A1F),
        inlineCode: .dyn(0xB8336A, 0xF28CB4),
        inlineCodeBackground: .dyn(0xEEEEF6, 0x262830),
        link: .dyn(0x4A4BCC, 0x9A9CFA),
        quoteBar: .dyn(0xC4C7EA, 0x3E4268),
        quoteBackground: .dyn(0xF1F1FB, 0x1B1D28),
        tableHeader: .dyn(0xEFF1F5, 0x22252D),
        tableRow: .dyn(0xFFFFFF, 0x1A1D22),
        tableRowAlt: .dyn(0xF8F9FB, 0x1E2127),
        listMarker: .dyn(0x8D94A3, 0x6C7383),
        tag: .dyn(0x5A5BE0, 0x9A9CFA),
        success: .dyn(0x1E9C6A, 0x3DC48B),
        warning: .dyn(0xD9781C, 0xF0A146),
        danger: .dyn(0xD8433F, 0xF06B65),
        running: .dyn(0x3B78F5, 0x6C9CFF),
        external: .dyn(0x8E4FD6, 0xB98BF0),
        shadow: .dynA(0x000000, 0.06, 0x000000, 0.35)
    )

    /// Values taken from Primary's "Classic Original" palette: light uses its
    /// gray-10…140 parchment scale, dark its brown-black scale.
    static let primary = Palette(
        background: .hsl(35, 36, 96, dark: (30, 19, 15)),            // gray-20 / d-gray-100
        sidebar: .hsl(34, 34, 90, dark: (29, 16, 13)),               // gray-40 / d-gray-120
        surface: .hsl(36, 38, 98, dark: (33, 20, 17)),               // gray-10 / d-gray-90
        surfaceAlt: .hsl(35, 37, 92, dark: (30, 17, 14)),            // gray-30 / d-gray-110
        border: .hsl(37, 38, 83, dark: (28, 22, 19)),                // gray-60 / d-gray-80
        borderStrong: .hsl(34, 37, 70, dark: (31, 27, 25)),          // gray-70 / d-gray-70
        hover: .hsl(35, 36, 94, dark: (33, 20, 17)),
        selection: .hsla(197, 82, 27, 0.5, dark: (197, 45, 29, 0.5)),  // nav selected
        selectionText: .hsl(35, 36, 96, dark: (32, 48, 85)),
        input: .hsl(35, 37, 92, dark: (24, 18, 11)),                 // form field
        text: .hsl(31, 45, 24, dark: (34, 39, 74)),                  // gray-130 / d-gray-20
        textMuted: .hsl(35, 28, 40, dark: (35, 27, 55)),             // gray-100 / d-gray-40
        textFaint: .hsl(34, 29, 60, dark: (34, 24, 46)),             // gray-80 / d-gray-50
        heading: .hsl(33, 54, 17, dark: (32, 48, 85)),               // gray-140 / d-gray-10
        accent: .hsl(30, 23, 54, dark: (30, 30, 36)),                // interactive accent
        accentHover: .hsl(28, 31, 60, dark: (28, 34, 41)),
        onAccent: .hsl(36, 38, 98, dark: (32, 48, 85)),
        focus: .hsl(31, 23, 50, dark: (34, 31, 68)),
        userBubble: .hsl(36, 35, 88, dark: (28, 22, 19)),            // gray-50 / d-gray-80
        userBubbleBorder: .hsl(37, 38, 83, dark: (31, 27, 25)),
        userText: .hsl(31, 45, 24, dark: (34, 39, 74)),
        code: .hsl(35, 37, 92, dark: (24, 18, 11)),
        codeHeader: .hsl(34, 34, 90, dark: (29, 16, 13)),
        inlineCode: .hsl(4, 59, 64, dark: (4, 91, 67)),              // red-10 / d-red-20
        inlineCodeBackground: .hsl(36, 38, 98, dark: (24, 18, 11)),
        link: .hsl(4, 72, 55, dark: (4, 91, 67)),                    // red-20
        quoteBar: .hsl(37, 38, 83, dark: (31, 27, 25)),
        quoteBackground: .hsl(36, 38, 98, dark: (29, 16, 13)),
        tableHeader: .hsl(35, 37, 92, dark: (24, 18, 11)),
        tableRow: .hsl(36, 38, 98, dark: (29, 16, 13)),
        tableRowAlt: .hsl(35, 36, 96, dark: (30, 17, 14)),
        listMarker: .hsl(34, 29, 60, dark: (34, 24, 46)),
        tag: .hsl(200, 64, 37, dark: (197, 48, 49)),                 // blue-30
        success: .hsl(149, 50, 39, dark: (152, 51, 54)),
        warning: .hsl(18, 69, 50, dark: (26, 85, 58)),
        danger: .hsl(4, 56, 48, dark: (4, 88, 61)),
        running: .hsl(200, 64, 37, dark: (194, 59, 56)),
        external: .hsl(275, 37, 43, dark: (242, 52, 69)),
        shadow: .dynA(0x000000, 0.07, 0x000000, 0.4)
    )
}

// MARK: - Color helpers

extension Color {
    /// A color that resolves per appearance (light / dark).
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamic(PlatformColor.rgb(light), PlatformColor.rgb(dark))
    }

    static func dynA(_ light: UInt32, _ la: CGFloat, _ dark: UInt32, _ da: CGFloat) -> Color {
        dynamic(PlatformColor.rgb(light).withAlphaComponent(la), PlatformColor.rgb(dark).withAlphaComponent(da))
    }

    static func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, dark d: (CGFloat, CGFloat, CGFloat)) -> Color {
        dynamic(PlatformColor.hsl(h, s, l), PlatformColor.hsl(d.0, d.1, d.2))
    }

    static func hsla(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat, dark d: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Color {
        dynamic(PlatformColor.hsl(h, s, l, a), PlatformColor.hsl(d.0, d.1, d.2, d.3))
    }

    static func dynamic(_ light: PlatformColor, _ dark: PlatformColor) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
        #else
        Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })
        #endif
    }
}

extension PlatformColor {
    static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> PlatformColor {
        #if os(macOS)
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        #else
        UIColor(red: r, green: g, blue: b, alpha: a)
        #endif
    }

    static func rgb(_ hex: UInt32) -> PlatformColor {
        srgb(CGFloat((hex >> 16) & 0xFF) / 255,
             CGFloat((hex >> 8) & 0xFF) / 255,
             CGFloat(hex & 0xFF) / 255)
    }

    /// CSS-style hsl(): hue in degrees, saturation and lightness in percent.
    static func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat = 1) -> PlatformColor {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var rgb: (CGFloat, CGFloat, CGFloat)
        switch hp {
        case 0..<1: rgb = (c, x, 0)
        case 1..<2: rgb = (x, c, 0)
        case 2..<3: rgb = (0, c, x)
        case 3..<4: rgb = (0, x, c)
        case 4..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        let m = l - c / 2
        return srgb(rgb.0 + m, rgb.1 + m, rgb.2 + m, a)
    }
}
