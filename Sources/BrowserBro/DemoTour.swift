import AppKit
import RoutingCore
import SwiftUI

/// `BROWSERBRO_DEMO=1 BrowserBro --demo-tour <dir>`: a scripted tour of the real picker, pulse and Settings
/// in demo mode, over a made-up "chat" stage, for README and website media.
///
/// The app does not capture the screen itself. It prints cues for an outside recorder:
/// - `MARK <name> begin|end <unix time>` around an animation (cut it from a screen recording);
/// - `CUE <name> <x> <y> <w> <h>` for a still (rect in points, top-left origin of the main display).
///   The tour then waits until `<dir>/<name>.ack` exists (max 20 s), so the recorder can take the shot.
/// The pointer is moved for the tour and put back at the end.
@MainActor
final class DemoTour {
    private let model: AppModel
    private let dir: URL
    private let stage = StageState()
    private var stageWindow: NSWindow?

    static var requested: Bool { DemoMode.argument(after: "--demo-tour") != nil }

    static let link = URL(string: "https://docs.example.org/q4-plan")!
    static let ruleLink = URL(string: "https://wiki.acme.com/onboarding")!

    init(model: AppModel) {
        self.model = model
        dir = URL(fileURLWithPath: DemoMode.argument(after: "--demo-tour") ?? "demo-tour")
    }

    func run() async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.rules.save(DemoMode.rules())
        model.settings.settings.pulseEnabled = true
        let startPointer = Self.pointer
        showStage()
        let r = stageRectTopLeft
        print("STAGE \(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))")
        await settle(1.0)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            stage.phase = .chat
            await settle(1.0)

            // Hero: click a link in the chat → picker at the pointer → glide to "Work" → choose → page opens.
            let linkPoint = stagePoint(CGPoint(x: stage.linkFrame.minX + 70, y: stage.linkFrame.minY + 18))
            let approach = CGPoint(x: linkPoint.x + 140, y: linkPoint.y + 110)
            await glide(to: approach, from: Self.pointer, seconds: 0.01)
            mark("hero-\(name)", "begin")
            // The pointer jump above is easy to find in a recorder's cursor log: it ties video time to wall time.
            print(String(format: "SYNC %.3f %d %d", Date().timeIntervalSince1970, Int(approach.x), Int(approach.y)))
            await settle(0.4)
            await glide(to: linkPoint, from: approach, seconds: 0.6)
            await settle(0.3)
            withAnimation(.easeOut(duration: 0.1)) { stage.pressed = true }
            await settle(0.12)
            withAnimation(.easeOut(duration: 0.2)) { stage.pressed = false }
            model.route(RouteRequest(url: Self.link, sourceBundleID: "com.apple.MobileSMS"))
            await settle(1.1)
            let work = model.drop.state.layout.tileFrame(1)
            let card = model.drop.frame
            // Tile 2 centre on screen: card frame (AppKit) → top-left points.
            let tile = CGPoint(x: card.minX + CursorPlacement.margin + work.midX,
                               y: mainHeight - card.maxY + CursorPlacement.margin + work.midY - 10)
            await glide(to: tile, from: Self.pointer, seconds: 0.35)
            model.drop.select(1)
            await settle(0.8)
            if let work = model.pickerChoices.first(where: { $0.target.id == DemoMode.chromeWork }) {
                model.drop.choose(work)
                stage.opened = work.target
            }
            await settle(0.3)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { stage.phase = .opened }
            await settle(2.0)
            mark("hero-\(name)", "end")
            withAnimation(.easeOut(duration: 0.3)) { stage.phase = .chat }
            await settle(0.8)

            // Keys: ⌥ held (private window) and "Always open here" on.
            await glide(to: linkPoint, from: Self.pointer, seconds: 0.01)
            model.route(RouteRequest(url: Self.link, sourceBundleID: "com.apple.MobileSMS"))
            await settle(1.0)
            model.drop.select(1)
            model.drop.state.optionHeld = true
            model.drop.state.alwaysHere = true
            await settle(0.8)
            await cue("keys-\(name)", topLeft(model.drop.frame))
            model.cancelAllPickers()
            await settle(0.9)

            // Pulse: a rule opens the link; a capsule next to the pointer says where it went.
            mark("pulse-\(name)", "begin")
            await settle(0.3)
            model.route(RouteRequest(url: Self.ruleLink, sourceBundleID: "com.apple.mail"))
            await settle(2.6)
            mark("pulse-\(name)", "end")

            // Settings → Rules (first rule open) and Tester (pre-filled with --demo-url).
            model.selectedRuleID = model.rules.file.rules.first?.id
            showSettings(.rules)
            await settle(1.5)
            if let w = settingsWindow { await cue("rules-\(name)", topLeft(w.frame)) }
            showSettings(.tester)
            await settle(1.2)
            if let w = settingsWindow { await cue("tester-\(name)", topLeft(w.frame)) }
            settingsWindow?.orderOut(nil)
            await settle(0.5)
        }

        await glide(to: startPointer, from: Self.pointer, seconds: 0.01)
        print("TOUR DONE")
        fflush(stdout)
        exit(0)
    }

    // MARK: Stage

    private var mainScreen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }
    private var mainHeight: CGFloat { mainScreen.frame.maxY }

    private func showStage() {
        let visible = mainScreen.visibleFrame
        let size = StageLayout.size
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .floating
        w.isOpaque = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: StageView(state: stage))
        w.setFrame(frame, display: true)
        w.orderFrontRegardless()
        stageWindow = w
    }

    private var stageRectTopLeft: CGRect { topLeft(stageWindow?.frame ?? .zero) }

    /// A point in stage coordinates (top-left) → global top-left points.
    private func stagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: stageRectTopLeft.minX + p.x, y: stageRectTopLeft.minY + p.y)
    }

    /// AppKit frame (bottom-left origin) → top-left origin of the main display.
    private func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    private var settingsWindow: NSWindow?

    /// The real Settings view in a window that joins every Space (also a full-screen one), above the stage.
    private func showSettings(_ pane: SettingsPane) {
        model.settingsPane = pane
        let w = settingsWindow ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "BrowserBro"
            w.toolbarStyle = .unified
            w.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            settingsWindow = w
            return w
        }()
        guard let s = stageWindow else { return }
        let size = CGSize(width: 1020, height: 640)
        w.setFrame(CGRect(x: s.frame.midX - size.width / 2, y: s.frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        w.orderFrontRegardless()
        NSApp.activate()
        w.makeKey()
    }

    // MARK: Pointer and cues

    /// Pointer position, top-left origin of the main display.
    private static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func glide(to end: CGPoint, from start: CGPoint, seconds: Double) async {
        let steps = max(1, Int(seconds * 60))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 // ease in-out
            CGWarpMouseCursorPosition(CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e))
            if steps > 1 { try? await Task.sleep(for: .milliseconds(16)) }
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func mark(_ name: String, _ edge: String) {
        print(String(format: "MARK %@ %@ %.3f", name, edge, Date().timeIntervalSince1970))
        fflush(stdout)
    }

    private func cue(_ name: String, _ rect: CGRect) async {
        let ack = dir.appending(path: "\(name).ack")
        try? FileManager.default.removeItem(at: ack)
        print("CUE \(name) \(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))")
        fflush(stdout)
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: ack.path) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Stage view

@MainActor
@Observable
final class StageState {
    enum Phase { case chat, opened }
    var phase = Phase.chat
    var pressed = false
    var opened: BrowserTarget?
    /// Where the chat link is, in stage coordinates (top-left).
    var linkFrame: CGRect = .zero
}

enum StageLayout {
    static let size = CGSize(width: 1120, height: 720)
    static let chat = CGRect(x: 90, y: 70, width: 500, height: 560)
    static let browser = CGRect(x: 440, y: 120, width: 600, height: 470)
}

private struct StageView: View {
    let state: StageState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            ChatCard(pressed: state.pressed, onLinkFrame: { if !state.pressed { state.linkFrame = $0 } })
                .frame(width: StageLayout.chat.width, height: StageLayout.chat.height)
                .offset(x: StageLayout.chat.minX, y: StageLayout.chat.minY)
            if state.phase == .opened, let target = state.opened {
                BrowserCard(target: target)
                    .frame(width: StageLayout.browser.width, height: StageLayout.browser.height)
                    .offset(x: StageLayout.browser.minX, y: StageLayout.browser.minY)
                    .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .frame(width: StageLayout.size.width, height: StageLayout.size.height, alignment: .topLeading)
    }

    private var wallpaper: some View {
        let colors: [Color] = scheme == .dark
            ? [Color(red: 0.10, green: 0.11, blue: 0.24), Color(red: 0.24, green: 0.13, blue: 0.32), Color(red: 0.05, green: 0.20, blue: 0.27)]
            : [Color(red: 0.62, green: 0.75, blue: 0.98), Color(red: 0.93, green: 0.76, blue: 0.86), Color(red: 0.99, green: 0.86, blue: 0.70)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct WindowChrome<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in
                    Circle().fill(c.opacity(0.85)).frame(width: 12, height: 12)
                }
                Spacer()
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 52, height: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            content
        }
        .background(.background, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
    }
}

private struct ChatCard: View {
    let pressed: Bool
    let onLinkFrame: (CGRect) -> Void

    var body: some View {
        WindowChrome(title: "Team chat") {
            VStack(alignment: .leading, spacing: 14) {
                message("A", .orange, "Alex", "Morning! The Q4 plan is ready 👇")
                // The link the pointer clicks: its centre is StageLayout.link.
                HStack(alignment: .top, spacing: 10) {
                    Color.clear.frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("docs.example.org/q4-plan")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .underline()
                        Text("Q4 plan · shared doc").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(pressed ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 14))
                    .scaleEffect(pressed ? 0.97 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onLinkFrame($0) }
                }
                message("J", .teal, "Jordan", "Nice. Let's go through it at 3.")
                Spacer()
                HStack {
                    Text("Message").foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: .capsule)
            }
            .padding(18)
        }
    }

    private func message(_ initial: String, _ color: Color, _ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(initial).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(color.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(text).font(.system(size: 14))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 14))
            }
        }
    }
}

private struct BrowserCard: View {
    let target: BrowserTarget

    var body: some View {
        WindowChrome(title: target.fullName) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    TargetIcon(target: target, size: 22)
                    Text("docs.example.org/q4-plan").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    if let profile = target.profileName {
                        Text(profile).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: .capsule)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
                Text("Q4 plan").font(.system(size: 26, weight: .bold))
                ForEach([0.9, 0.75, 0.82, 0.6, 0.7], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18))
                        .frame(width: 520 * w, height: 10)
                }
                Spacer()
            }
            .padding(20)
        }
    }
}
