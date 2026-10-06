import Foundation
import SwiftUI

/// Liquid Glass on macOS 26 and later; a classic material look with the same layout and motion
/// on macOS 14–15. Every macOS-26-only glass API in the app goes through these helpers.
enum LiquidGlass {
    /// `BROWSERBRO_FORCE_LEGACY_UI=1` takes the macOS 14–15 path on macOS 26 too, to check the fallback.
    static let forceLegacy = ProcessInfo.processInfo.environment["BROWSERBRO_FORCE_LEGACY_UI"] == "1"

    static var isAvailable: Bool {
        if forceLegacy { return false }
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// `GlassEffectContainer` on macOS 26 (nearby glass shapes blend and morph); a plain container before.
struct BBGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *), LiquidGlass.isAvailable {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    /// A glass surface behind the view, in a rounded rectangle.
    /// `enabled: false` keeps the shape but draws nothing (Reduce Transparency draws its own background).
    @ViewBuilder
    func bbGlass(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false, enabled: Bool = true) -> some View {
        if #available(macOS 26, *), LiquidGlass.isAvailable {
            glassEffect(Self.glass(enabled: enabled, tint: tint, interactive: interactive), in: .rect(cornerRadius: cornerRadius))
        } else if enabled {
            modifier(MaterialSurface(cornerRadius: cornerRadius, tint: tint))
        } else {
            self
        }
    }

    @available(macOS 26, *)
    private static func glass(enabled: Bool, tint: Color?, interactive: Bool) -> Glass {
        guard enabled else { return .identity }
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// The glass materializes in and out on macOS 26. Before 26 the view's own `.transition` does the work.
    @ViewBuilder
    func bbGlassMaterialize(reduceMotion: Bool) -> some View {
        if #available(macOS 26, *), LiquidGlass.isAvailable {
            glassEffectTransition(reduceMotion ? .identity : .materialize)
        } else {
            self
        }
    }

    /// Liquid Glass button style on macOS 26 (prominent = tinted); bordered styles before.
    @ViewBuilder
    func bbGlassButtonStyle(prominent: Bool) -> some View {
        if #available(macOS 26, *), LiquidGlass.isAvailable {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// macOS 14–15 stand-in for a glass surface: translucent material, optional tint,
/// a hairline edge and a soft shadow.
private struct MaterialSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(tint == nil ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial))
                    if let tint { shape.fill(tint) }
                }
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(tint == nil ? 0.18 : 0.08), radius: tint == nil ? 12 : 3, y: tint == nil ? 4 : 1)
            }
    }
}
