import AppKit
import RoutingCore
import SwiftUI

/// The shape of the picker's one glass surface. It morphs between these.
enum DropSurface: Equatable {
    /// A small glass drop at a point (card coordinates): where the picker grows from and shrinks back to.
    case seed(CGPoint)
    /// The full panel.
    case open
    /// Shrunk onto a tile, after that tile was chosen.
    case tile(Int)
    /// Removed (the glass dematerializes).
    case gone
}

/// UI state of the picker.
@MainActor
@Observable
final class DropState {
    /// Logical state: the picker takes keys and clicks. Visuals follow `surface`.
    var isOpen = false
    var selected = 0
    var alwaysHere = false
    var optionHeld = false
    var layout = DropLayout(count: 1)
    var surface = DropSurface.gone
    /// Header, tiles and footer fade in one after another once the glass has grown.
    var contentShown = false
    /// The lens swells briefly on the chosen tile.
    var lensPulse = false
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
    static let tileCorner: CGFloat = 18
    static let seed: CGFloat = 28

    let columns: Int
    let rows: Int

    init(count: Int) {
        columns = max(1, min(count, Self.perRow))
        rows = max(1, Int((Double(count) / Double(Self.perRow)).rounded(.up)))
    }

    var size: CGSize {
        CGSize(width: max(380, CGFloat(columns) * Self.tile.width + CGFloat(columns - 1) * Self.gap + 2 * Self.side),
               height: Self.top + Self.header + gridHeight + Self.footer)
    }

    var gridHeight: CGFloat { CGFloat(rows) * Self.tile.height + CGFloat(rows - 1) * Self.gap }

    /// Frame of tile `index` in card coordinates (top-left origin). The grid is centred; the last row starts on the left.
    func tileFrame(_ index: Int) -> CGRect {
        let gridWidth = CGFloat(columns) * Self.tile.width + CGFloat(columns - 1) * Self.gap
        let x0 = (size.width - gridWidth) / 2
        let col = index % columns, row = index / columns
        return CGRect(x: x0 + CGFloat(col) * (Self.tile.width + Self.gap),
                      y: Self.top + Self.header + CGFloat(row) * (Self.tile.height + Self.gap),
                      width: Self.tile.width, height: Self.tile.height)
    }

    /// The icon of the first tile: it lands under the pointer, so choice 1 needs no mouse travel.
    var hotSpot: CGPoint {
        let r = tileFrame(0)
        return CGPoint(x: r.midX, y: r.minY + 28)
    }

    /// Frame of the glass surface for a state, in card coordinates, with its corner radius.
    func surfaceFrame(_ surface: DropSurface) -> (rect: CGRect, corner: CGFloat) {
        switch surface {
        case .open, .gone:
            return (CGRect(origin: .zero, size: size), Self.corner)
        case .seed(let p):
            return (CGRect(x: p.x - Self.seed / 2, y: p.y - Self.seed / 2, width: Self.seed, height: Self.seed), Self.seed / 2)
        case .tile(let i):
            return (tileFrame(i), Self.tileCorner)
        }
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
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    /// The tile that was just chosen: the surface shrinks onto it when the picker closes.
    private var chosenIndex: Int?
    /// Where the pointer was when the picker opened (for the self-test).
    private(set) var lastPointer: CGPoint = .zero

    /// The lens moves between tiles with this spring.
    static let lensSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible == true && state.isOpen }

    func present() {
        closeTask?.cancel()
        let choices = model.pickerChoices
        let layout = DropLayout(count: choices.count)
        let wasOpen = isVisible
        chosenIndex = nil
        state.alwaysHere = false
        state.optionHeld = NSEvent.modifierFlags.contains(.option)
        let p = panel ?? makePanel()
        if !wasOpen || state.layout != layout {
            lastPointer = NSEvent.mouseLocation
            // Open where the pointer is: the user just clicked the link there.
            let placement = CursorPlacement.frame(content: layout.size, hotSpot: layout.hotSpot)
            state.layout = layout
            p.setFrame(placement.frame, display: true)
        }
        if wasOpen {
            // Next link in the queue: the panel stays, the lens glides back to tile 1.
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Self.lensSpring) { state.selected = 0 }
        } else {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                state.selected = 0
                state.contentShown = false
                state.lensPulse = false
                state.surface = .seed(pointerInCard(p))
            }
        }
        state.isOpen = true
        p.orderFrontRegardless()
        p.makeKey()
        installMonitors()
        if !wasOpen {
            openTask?.cancel()
            openTask = Task { @MainActor in
                // One frame with the seed on screen, so the glass visibly grows out of the pointer.
                guard await pause(16), state.isOpen else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.8)) {
                    state.surface = .open
                }
                state.contentShown = true
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
        let chosen = chosenIndex
        chosenIndex = nil
        state.isOpen = false
        guard let p = panel, p.isVisible else { return }
        openTask?.cancel()
        closeTask?.cancel()
        let reduceMotion = reduceMotion
        closeTask = Task { @MainActor in
            if reduceMotion {
                // Cross-fade only.
                withAnimation(.easeOut(duration: 0.15)) {
                    state.contentShown = false
                    state.surface = .gone
                }
                guard await pause(160) else { return }
            } else {
                if let chosen {
                    // The chosen tile's lens swells, then the whole panel shrinks onto that tile.
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) { state.lensPulse = true }
                    guard await pause(110) else { return }
                    state.contentShown = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        state.lensPulse = false
                        state.surface = .tile(chosen)
                    }
                } else {
                    // Esc or a click outside: the panel flows back into the pointer.
                    state.contentShown = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        state.surface = .seed(pointerInCard(p))
                    }
                }
                guard await pause(210) else { return }
                withAnimation(.easeOut(duration: 0.16)) { state.surface = .gone }
                guard await pause(170) else { return }
            }
            p.orderOut(nil)
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The mouse pointer in card coordinates (top-left origin), kept inside the card.
    private func pointerInCard(_ p: NSWindow) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let size = state.layout.size
        let m = CursorPlacement.margin
        let inset = DropLayout.seed / 2
        let x = mouse.x - p.frame.minX - m
        let y = p.frame.maxY - mouse.y - m
        return CGPoint(x: min(max(x, inset), size.width - inset), y: min(max(y, inset), size.height - inset))
    }

    /// Sleeps; false when the task was cancelled (a new link arrived meanwhile).
    private func pause(_ ms: Int) async -> Bool {
        try? await Task.sleep(for: .milliseconds(ms))
        return !Task.isCancelled
    }

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
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyLink()
            return true
        }
        return false
    }

    private func move(_ delta: Int, count: Int) {
        let next = state.selected + delta
        select((next % count + count) % count)
    }

    /// Moves the lens to a tile.
    func select(_ index: Int) {
        guard index != state.selected else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Self.lensSpring) {
            state.selected = index
        }
    }

    func choose(_ choice: PickerChoice, option: Bool = false) {
        if let i = model.pickerChoices.firstIndex(where: { $0.id == choice.id }) {
            if i != state.selected { select(i) }
            chosenIndex = i
        }
        model.choose(choice, privateWindow: option || state.optionHeld || NSEvent.modifierFlags.contains(.option), alwaysHere: state.alwaysHere)
    }

    func copyLink() {
        guard let item = model.pickerQueue.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.request.url.absoluteString, forType: .string)
    }

    var windowNumber: Int { panel?.windowNumber ?? 0 }
    var frame: CGRect { panel?.frame ?? .zero }
}

// MARK: - Views

struct DropView: View {
    let model: AppModel
    @Bindable var state: DropState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = state.layout.size
        // Reduce Motion: no morph, the full panel just fades.
        let shown: DropSurface = reduceMotion ? (state.surface == .gone ? .gone : .open) : state.surface
        let (rect, corner) = state.layout.surfaceFrame(shown)
        ZStack(alignment: .topLeading) {
            Color.clear
            if reduceTransparency {
                surface(rect)
                    .background {
                        RoundedRectangle(cornerRadius: corner, style: .continuous).fill(.windowBackground)
                            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.separator))
                    }
                    .offset(x: rect.minX, y: rect.minY)
                    .opacity(shown == .gone ? 0 : 1)
            } else {
                GlassEffectContainer {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        if shown != .gone {
                            // The content lives inside the glass, so text and symbols get the glass's
                            // adaptive (vibrant) colours over light and dark backdrops.
                            surface(rect)
                                .glassEffect(.regular, in: .rect(cornerRadius: corner))
                                .glassEffectTransition(reduceMotion ? .identity : .materialize)
                                .transition(.opacity)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .padding(CursorPlacement.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The surface at its current frame, carrying the full-size content pinned to the card.
    private func surface(_ rect: CGRect) -> some View {
        let size = state.layout.size
        return Color.clear
            .frame(width: rect.width, height: rect.height)
            .overlay(alignment: .topLeading) {
                DropContent(model: model, state: state)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .offset(x: -rect.minX, y: -rect.minY)
                    .allowsHitTesting(state.isOpen)
            }
    }
}

/// Content fades in after the glass: header first, then tiles left to right, then the footer.
private struct Stagger: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .animation(shown ? .easeOut(duration: 0.22).delay(reduceMotion ? 0 : delay) : .easeIn(duration: 0.08), value: shown)
    }
}

private extension View {
    func stagger(_ shown: Bool, delay: Double) -> some View { modifier(Stagger(shown: shown, delay: delay)) }
}

private struct DropContent: View {
    let model: AppModel
    @Bindable var state: DropState

    var body: some View {
        let choices = model.pickerChoices
        let item = model.pickerQueue.first
        let layout = state.layout
        let gridOrigin = CGPoint(x: DropLayout.side, y: DropLayout.top + DropLayout.header)
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let item {
                    DropHeader(item: item, position: 1, total: model.pickerQueue.count)
                } else {
                    Color.clear.frame(height: DropLayout.header - 8)
                }
            }
            .stagger(state.contentShown, delay: 0.08)

            ZStack(alignment: .topLeading) {
                Color.clear
                if !choices.isEmpty {
                    let selected = min(state.selected, choices.count - 1)
                    LensView(frame: layout.tileFrame(selected).offsetBy(dx: -gridOrigin.x, dy: -gridOrigin.y),
                             choice: choices[selected],
                             privateMode: state.optionHeld && choices[selected].target.family.supportsPrivate,
                             visible: state.contentShown || state.lensPulse,
                             pulse: state.lensPulse)
                }
                ForEach(Array(choices.enumerated()), id: \.element.id) { idx, choice in
                    let f = layout.tileFrame(idx).offsetBy(dx: -gridOrigin.x, dy: -gridOrigin.y)
                    TileView(choice: choice, selected: idx == state.selected, privateMode: state.optionHeld && choice.target.family.supportsPrivate)
                        .onHover { if $0 { model.drop.select(idx) } }
                        .onTapGesture { model.drop.choose(choice) }
                        .offset(x: f.minX, y: f.minY)
                        .stagger(state.contentShown, delay: 0.12 + Double(idx) * 0.015)
                }
            }
            .frame(width: layout.size.width - 2 * DropLayout.side, height: layout.gridHeight, alignment: .topLeading)

            DropFooter(model: model, state: state, domain: item.map { HostNormalizer.siteDomain(of: $0.request.url) } ?? "")
                .stagger(state.contentShown, delay: 0.14 + Double(choices.count) * 0.015)
        }
        .padding(.horizontal, DropLayout.side)
        .padding(.top, DropLayout.top)
    }
}

/// The one moving glass lens that marks the selected tile. It glides from tile to tile on a spring.
private struct LensView: View {
    let frame: CGRect
    let choice: PickerChoice
    let privateMode: Bool
    let visible: Bool
    let pulse: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let tint = privateMode ? Color.purple : (choice.target.tint.map { Color(nsColor: $0.nsColor) } ?? Color.accentColor)
        let shape = RoundedRectangle(cornerRadius: DropLayout.tileCorner, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(tint.opacity(0.35))
            } else {
                GlassEffectContainer {
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: .rect(cornerRadius: DropLayout.tileCorner))
                }
            }
        }
        .overlay {
            if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
        }
        .frame(width: frame.width, height: frame.height)
        // Reduce Motion: the lens cross-fades to the new tile instead of gliding.
        .id(reduceMotion ? AnyHashable(choice.id.description) : AnyHashable("lens"))
        .transition(.opacity)
        .scaleEffect(pulse ? 1.08 : 1)
        .offset(x: frame.minX, y: frame.minY)
        .opacity(visible ? 1 : 0)
        .animation(visible ? .easeOut(duration: 0.2).delay(reduceMotion ? 0 : 0.1) : .easeIn(duration: 0.12), value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                            .background(.quaternary, in: .capsule)
                    }
                }
                if let note = item.note {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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

/// Plain content on the panel glass. The selection is drawn by the lens behind it.
private struct TileView: View {
    let choice: PickerChoice
    let selected: Bool
    let privateMode: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 3) {
            TargetIcon(target: choice.target, size: 40)
                .overlay(alignment: .topLeading) {
                    if privateMode {
                        Image(systemName: "theatermasks.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.purple)
                            .padding(3)
                            .background(.background, in: .circle)
                            .offset(x: -8, y: -6)
                    }
                }
                .scaleEffect(selected ? 1.06 : 1)
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
        .contentShape(.rect(cornerRadius: DropLayout.tileCorner))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(choice.target.appName)\(choice.target.profileName.map { ", \($0) profile" } ?? "")\(choice.key.map { ", key \($0)" } ?? "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct DropFooter: View {
    let model: AppModel
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
            }
            .glassStyle(prominent: state.alwaysHere)
            .disabled(domain.isEmpty)
            .accessibilityLabel("Always open \(domain) here")
            .accessibilityValue(state.alwaysHere ? "on" : "off")

            Spacer(minLength: 8)
            KeyChip(symbol: "⌥", text: "private", active: state.optionHeld) { state.optionHeld.toggle() }
                .accessibilityLabel("Private window")
                .accessibilityValue(state.optionHeld ? "on" : "off")
            KeyChip(symbol: "⌘C", text: "copy", active: false) { model.drop.copyLink() }
                .accessibilityLabel("Copy link")
            KeyChip(symbol: "esc", text: "cancel", active: false) { model.cancelPicker() }
                .accessibilityLabel("Cancel")
        }
        .controlSize(.small)
        .frame(height: DropLayout.footer - 8)
    }
}

private struct KeyChip: View {
    let symbol: String
    let text: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(symbol).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 10))
            }
        }
        .glassStyle(prominent: active)
    }
}

extension View {
    /// System Liquid Glass button style; prominent (tinted) when on.
    @ViewBuilder
    func glassStyle(prominent: Bool) -> some View {
        if prominent {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.glass)
        }
    }
}
