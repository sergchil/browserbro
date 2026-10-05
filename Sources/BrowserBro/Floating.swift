import AppKit
import SwiftUI

/// Places a floating surface next to the mouse pointer, kept inside the visible part of that screen.
enum CursorPlacement {
    /// Space around the content for the shadow. The window is larger than the visible card by this much.
    static let margin: CGFloat = 30

    struct Result {
        let frame: CGRect
        /// Where the pointer is inside the window, as a unit point (SwiftUI, top-left origin). Used as the animation anchor.
        let anchor: UnitPoint
    }

    /// - Parameters:
    ///   - content: size of the visible card.
    ///   - hotSpot: the point inside the card (top-left origin) that should land under the pointer.
    @MainActor
    static func frame(content: CGSize, hotSpot: CGPoint, at mouse: CGPoint = NSEvent.mouseLocation) -> Result {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: content.width + 2 * margin, height: content.height + 2 * margin)
        // Convert the hot spot (top-left origin) to AppKit window coordinates (bottom-left origin).
        var x = mouse.x - margin - hotSpot.x
        var y = mouse.y - (size.height - margin - hotSpot.y)
        // Keep the card (not the shadow margin) on screen.
        x = min(max(x, visible.minX - margin), visible.maxX - size.width + margin)
        y = min(max(y, visible.minY - margin), visible.maxY - size.height + margin)
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        let anchor = UnitPoint(x: (mouse.x - frame.minX) / size.width, y: 1 - (mouse.y - frame.minY) / size.height)
        return Result(frame: frame, anchor: anchor)
    }
}

/// A borderless panel that floats above other windows and can take keys without activating the app.
final class FloatingPanel: NSPanel {
    init(keyable: Bool) {
        self.keyable = keyable
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    private let keyable: Bool
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// Small helpers shared by the floating views.
enum AppIcons {
    @MainActor static var cache: [URL: NSImage] = [:]

    @MainActor static func icon(for appURL: URL) -> NSImage {
        if let i = cache[appURL] { return i }
        let i = NSWorkspace.shared.icon(forFile: appURL.path)
        cache[appURL] = i
        return i
    }

    @MainActor static func icon(bundleID: String?) -> NSImage? {
        guard let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return icon(for: url)
    }

    static func appName(bundleID: String?) -> String? {
        guard let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Browser icon with an optional profile badge (picture or monogram).
struct TargetIcon: View {
    let target: BrowserTarget
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: AppIcons.icon(for: target.appURL))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let name = target.profileName {
                    ProfileBadge(name: name, tint: target.tint, avatarURL: target.avatarURL)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .offset(x: size * 0.08, y: size * 0.06)
                }
            }
            .accessibilityHidden(true)
    }
}

struct ProfileBadge: View {
    let name: String
    let tint: RGB?
    let avatarURL: URL?

    var body: some View {
        Group {
            if let url = avatarURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.map { Color(nsColor: $0.nsColor) } ?? Color.accentColor)
            }
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
    }
}
