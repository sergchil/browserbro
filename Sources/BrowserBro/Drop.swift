import AppKit
import RoutingCore
import SwiftUI

/// UI state of the picker.
@MainActor
@Observable
final class DropState {
    var isOpen = false
    var selected = 0
    var alwaysHere = false
    var optionHeld = false
    var layout = DropLayout(count: 1)
    /// Pointer position inside the window: the card grows out of this point.
    var anchor = UnitPoint.topLeading
}

struct DropLayout: Equatable {
    static let tile = CGSize(width: 92, height: 100)
    static let gap: CGFloat = 10
    static let side: CGFloat = 18
    static let top: CGFloat = 14
    static let header: CGFloat = 50
    static let footer: CGFloat = 46
    static let perRow = 6
    static let corner: CGFloat = 26

    let columns: Int
    let rows: Int

    init(count: Int) {
        columns = max(1, min(count, Self.perRow))
        rows = max(1, Int((Double(count) / Double(Self.perRow)).rounded(.up)))
    }

    var size: CGSize {
        CGSize(width: max(380, CGFloat(columns) * Self.tile.width + CGFloat(columns - 1) * Self.gap + 2 * Self.side),
               height: Self.top + Self.header + CGFloat(rows) * Self.tile.height + CGFloat(rows - 1) * Self.gap + Self.footer)
    }

    /// The icon of the first tile: it lands under the pointer, so choice 1 needs no mouse travel.
    var hotSpot: CGPoint {
        CGPoint(x: Self.side + Self.tile.width / 2, y: Self.top + Self.header + 8 + 20)
    }
}

/// Shows the picker next to the pointer, handles keys and clicks outside.
@MainActor
final class DropController {
    private unowned let model: AppModel
    let state = DropState()
    private var panel: FloatingPanel?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var closeTask: Task<Void, Never>?
    /// Where the pointer was when the picker opened (for the self-test).
    private(set) var lastPointer: CGPoint = .zero

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible == true && state.isOpen }

    func present() {
        closeTask?.cancel()
        let choices = model.pickerChoices
        let layout = DropLayout(count: choices.count)
        let wasOpen = isVisible
        state.selected = 0
        state.alwaysHere = false
        state.optionHeld = NSEvent.modifierFlags.contains(.option)
        let p = panel ?? makePanel()
        if !wasOpen || state.layout != layout {
            lastPointer = NSEvent.mouseLocation
            // Open where the pointer is: the user just clicked the link there.
            let placement = CursorPlacement.frame(content: layout.size, hotSpot: layout.hotSpot)
            state.layout = layout
            state.anchor = placement.anchor
            p.setFrame(placement.frame, display: true)
        }
        p.orderFrontRegardless()
        p.makeKey()
        installMonitors()
        if !wasOpen {
            state.isOpen = false
            // Open on the next frame so SwiftUI animates the card growing out of the pointer.
            DispatchQueue.main.async {
                withAnimation(self.reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.78)) {
                    self.state.isOpen = true
                }
            }
            if let item = model.pickerQueue.first {
                let host = item.request.url.host() ?? item.request.url.absoluteString
                NSAccessibility.post(element: p, notification: .announcementRequested,
                                     userInfo: [.announcement: "Open \(host). \(choices.count) choices.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }

    func dismiss() {
        removeMonitors()
        guard let p = panel, p.isVisible else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.9)) {
            state.isOpen = false
        }
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { p.orderOut(nil) }
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(keyable: true)
        p.contentView = NSHostingView(rootView: DropView(model: model, state: state))
        p.setAccessibilityLabel("BrowserBro picker")
        panel = p
        return p
    }

    // MARK: Keys

    private func installMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                nonisolated(unsafe) let e = event
                let used = MainActor.assumeIsolated { self?.handle(e) == true }
                return used ? nil : event
            }
        }
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.cancelAllPickers()
                }
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        outsideMonitor = nil
    }

    /// Returns true when the event was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        if event.type == .flagsChanged {
            state.optionHeld = event.modifierFlags.contains(.option)
            return false
        }
        let choices = model.pickerChoices
        guard !choices.isEmpty else { return false }
        let cols = state.layout.columns
        switch event.keyCode {
        case 53: model.cancelPicker(); return true                     // Esc
        case 36, 76: choose(choices[min(state.selected, choices.count - 1)], option: event.modifierFlags.contains(.option)); return true // Return
        case 48: state.alwaysHere.toggle(); return true                 // Tab
        case 123: move(-1, count: choices.count); return true           // ←
        case 124: move(1, count: choices.count); return true            // →
        case 125: move(cols, count: choices.count); return true         // ↓
        case 126: move(-cols, count: choices.count); return true        // ↑
        default: break
        }
        if let ch = event.charactersIgnoringModifiers, let n = Int(ch), let c = choices.first(where: { $0.key == n }) {
            choose(c, option: event.modifierFlags.contains(.option))
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let item = model.pickerQueue.first {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.request.url.absoluteString, forType: .string)
            return true
        }
        return false
    }

    private func move(_ delta: Int, count: Int) {
        let next = state.selected + delta
        let animation: Animation = reduceMotion ? .linear(duration: 0) : .spring(response: 0.28, dampingFraction: 0.82)
        withAnimation(animation) {
            state.selected = (next % count + count) % count
        }
    }

    func choose(_ choice: PickerChoice, option: Bool = false) {
        model.choose(choice, privateWindow: option || state.optionHeld || NSEvent.modifierFlags.contains(.option), alwaysHere: state.alwaysHere)
    }

    var windowNumber: Int { panel?.windowNumber ?? 0 }
    var frame: CGRect { panel?.frame ?? .zero }
}

// MARK: - Views

struct DropView: View {
    let model: AppModel
    @Bindable var state: DropState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let size = state.layout.size
        let open = state.isOpen
        DropContent(model: model, state: state)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: DropLayout.corner, style: .continuous).fill(.windowBackground)
                        .overlay(RoundedRectangle(cornerRadius: DropLayout.corner, style: .continuous).strokeBorder(.separator))
                }
            }
            .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(cornerRadius: DropLayout.corner))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(CursorPlacement.margin)
            .scaleEffect(open ? 1 : 0.6, anchor: state.anchor)
            .opacity(open ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropContent: View {
    let model: AppModel
    @Bindable var state: DropState
    @Namespace private var glass

    var body: some View {
        let choices = model.pickerChoices
        let item = model.pickerQueue.first
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                DropHeader(item: item, position: 1, total: model.pickerQueue.count)
            }
            GlassEffectContainer(spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(DropLayout.tile.width), spacing: DropLayout.gap), count: state.layout.columns),
                          spacing: DropLayout.gap) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { idx, choice in
                        TileView(choice: choice, selected: idx == state.selected, privateMode: state.optionHeld && choice.target.family.supportsPrivate)
                            .glassEffectID(choice.id.description, in: glass)
                            .onHover { if $0 { state.selected = idx } }
                            .onTapGesture { model.drop.choose(choice) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            DropFooter(state: state, domain: item.map { HostNormalizer.siteDomain(of: $0.request.url) } ?? "")
        }
        .padding(.horizontal, DropLayout.side)
        .padding(.top, DropLayout.top)
    }
}

private struct DropHeader: View {
    let item: PickerItem
    let position: Int
    let total: Int

    var body: some View {
        let url = item.request.url
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: url.isFileURL ? "doc" : "globe")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(url.isFileURL ? url.lastPathComponent : (url.host() ?? url.absoluteString))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if total > 1 {
                        Text("\(position) of \(total)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                Text(item.note ?? url.absoluteString)
                    .font(.system(size: 11))
                    .foregroundStyle(item.note == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let source = item.request.sourceBundleID {
                HStack(spacing: 5) {
                    Text("from").foregroundStyle(.secondary)
                    if let icon = AppIcons.icon(bundleID: source) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text(AppIcons.appName(bundleID: source) ?? source).lineLimit(1)
                }
                .font(.system(size: 11))
            }
        }
        .frame(height: DropLayout.header - 8, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

private struct TileView: View {
    let choice: PickerChoice
    let selected: Bool
    let privateMode: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tint = choice.target.tint.map { Color(nsColor: $0.nsColor) } ?? Color.accentColor
        VStack(spacing: 3) {
            TargetIcon(target: choice.target, size: 40)
                .overlay(alignment: .topLeading) {
                    if privateMode {
                        Image(systemName: "theatermasks.fill")
                            .font(.system(size: 11))
                            .padding(3)
                            .glassEffect(.regular.tint(.purple), in: .circle)
                            .offset(x: -8, y: -6)
                    }
                }
                .padding(.top, 8)
            Text(choice.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(choice.subtitle ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(choice.key.map(String.init) ?? " ")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(contrast == .increased ? .primary : .secondary)
                .frame(minWidth: 18)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary.opacity(choice.key == nil ? 0 : 1)))
        }
        .padding(.horizontal, 6)
        .frame(width: DropLayout.tile.width, height: DropLayout.tile.height, alignment: .top)
        .scaleEffect(selected ? 1.04 : 1)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? AnyShapeStyle(tint.opacity(0.45)) : AnyShapeStyle(.quaternary))
            }
        }
        .glassEffect(reduceTransparency ? .identity
                     : (selected ? .regular.tint((privateMode ? Color.purple : tint).opacity(0.35)).interactive() : .regular.interactive()),
                     in: .rect(cornerRadius: 18))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator, lineWidth: 1)
            }
        }
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(choice.target.appName)\(choice.target.profileName.map { ", \($0) profile" } ?? "")\(choice.key.map { ", key \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }
}

private struct DropFooter: View {
    @Bindable var state: DropState
    let domain: String

    var body: some View {
        HStack(spacing: 8) {
            Button {
                state.alwaysHere.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: state.alwaysHere ? "checkmark.circle.fill" : "circle")
                    Text("Always open \(domain.isEmpty ? "this site" : domain) here")
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("⇥").foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .glassEffect(state.alwaysHere ? .regular.tint(.accentColor.opacity(0.6)).interactive() : .regular.interactive(), in: .capsule)
            .disabled(domain.isEmpty)
            .accessibilityLabel("Always open \(domain) here")
            .accessibilityValue(state.alwaysHere ? "on" : "off")

            Spacer(minLength: 8)
            KeyHint(symbol: "⌥", text: "private", active: state.optionHeld)
            KeyHint(symbol: "⌘C", text: "copy", active: false)
            KeyHint(symbol: "esc", text: "cancel", active: false)
        }
        .frame(height: DropLayout.footer - 8)
    }
}

private struct KeyHint: View {
    let symbol: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(active ? .primary : .secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glassEffect(active ? .regular.tint(.purple.opacity(0.6)) : .regular, in: .capsule)
    }
}
