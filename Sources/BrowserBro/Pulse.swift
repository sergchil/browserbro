import AppKit
import RoutingCore
import SwiftUI

@MainActor
@Observable
final class PulseState {
    var isOpen = false
    var target: BrowserTarget?
    var request: RouteRequest?
    var message: String?
    var hovering = false
    var anchor = UnitPoint.topLeading
}

/// A small glass capsule next to the pointer after a rule opened a link: "→ Chrome · Work ›".
/// Click it to open the same link somewhere else.
@MainActor
final class PulseController {
    private unowned let model: AppModel
    let state = PulseState()
    private var panel: FloatingPanel?
    private var hideTask: Task<Void, Never>?

    static let height: CGFloat = 34
    static let linkWidth: CGFloat = 260
    static let messageWidth: CGFloat = 420
    /// Offset from the pointer, so the capsule never sits under it and blocks the next click.
    static let offset = CGPoint(x: -18, y: -26)

    init(model: AppModel) { self.model = model }

    func show(target: BrowserTarget, request: RouteRequest) {
        state.message = nil
        state.target = target
        state.request = request
        present(duration: 1.6)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Opened in \(target.fullName)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func showMessage(_ text: String) {
        state.message = text
        state.target = nil
        state.request = nil
        present(duration: 4)
    }

    private func present(duration: Double) {
        if model.drop.isVisible { return } // never cover the picker
        let p = panel ?? makePanel()
        let size = CGSize(width: state.message != nil ? Self.messageWidth : Self.linkWidth, height: state.message != nil ? 52 : Self.height)
        // Hot spot outside the card (negative) puts the card just below-right of the pointer.
        let placement = CursorPlacement.frame(content: size, hotSpot: Self.offset)
        state.anchor = placement.anchor
        p.setFrame(placement.frame, display: true)
        p.orderFrontRegardless()
        if !state.isOpen {
            DispatchQueue.main.async {
                withAnimation(self.animation) { self.state.isOpen = true }
            }
        }
        scheduleHide(after: duration)
    }

    private var animation: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            // Stay while the pointer is over it.
            while state.hovering && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    func hide() {
        withAnimation(animation) { state.isOpen = false }
        let p = panel
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !self.state.isOpen { p?.orderOut(nil) }
        }
    }

    func openElsewhere() {
        guard let req = state.request else { hide(); return }
        hideTask?.cancel()
        state.isOpen = false
        panel?.orderOut(nil)
        model.reopen(req)
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(keyable: false)
        p.contentView = NSHostingView(rootView: PulseView(state: state, onTap: { [weak self] in self?.openElsewhere() }))
        panel = p
        return p
    }
}

struct PulseView: View {
    @Bindable var state: PulseState
    let onTap: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let open = state.isOpen
        content
            .padding(.horizontal, 14)
            .frame(height: state.message != nil ? 52 : PulseController.height)
            .frame(maxWidth: state.message != nil ? PulseController.messageWidth : PulseController.linkWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                if reduceTransparency { Capsule().fill(.windowBackground).overlay(Capsule().strokeBorder(.separator)) }
            }
            .glassEffect(reduceTransparency ? .identity : .regular.interactive(), in: .rect(cornerRadius: 17))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .contentShape(.rect(cornerRadius: 17))
            .onHover { state.hovering = $0 }
            .onTapGesture { onTap() }
            .padding(CursorPlacement.margin)
            .scaleEffect(open ? 1 : 0.6, anchor: state.anchor)
            .opacity(open ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if let message = state.message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
        } else if let target = state.target {
            HStack(spacing: 7) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                TargetIcon(target: target, size: 20)
                Text(target.fullName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Opened in \(target.fullName). Click to open elsewhere.")
        }
    }
}
