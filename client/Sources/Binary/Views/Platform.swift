import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The few AppKit / UIKit types the shared code touches, under one name, so
// the same files build the macOS app and the iOS app (client/iOS).

#if os(macOS)
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

extension Image {
    init(platformImage image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension PlatformImage {
    /// A decoded bitmap at one point per pixel.
    convenience init(bitmap cg: CGImage) {
        #if os(macOS)
        self.init(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        self.init(cgImage: cg)
        #endif
    }
}

/// Puts text on the clipboard.
func copy(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}

/// Hands a link to the system (browser, Mail, …).
@MainActor
func openExternal(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
