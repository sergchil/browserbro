import AppKit
import RoutingCore

/// In-app integration test: `BrowserBro --self-test`.
///
/// Runs the real picker panel, real key handling and real rule saving against a temporary
/// rules folder (`BROWSERBRO_SUPPORT_DIR`), with browser launches recorded instead of performed.
/// Prints PASS/FAIL per check and exits 0 when everything passed.
@MainActor
final class SelfTest {
    private let model: AppModel
    private var launched: [(URL, TargetID, TargetOptions)] = []
    private var failures = 0
    private var checks = 0

    init(model: AppModel) { self.model = model }

    static var requested: Bool { CommandLine.arguments.contains("--self-test") }

    func run() async {
        model.launchOverride = { [weak self] url, target, options in
            self?.launched.append((url, target.id, options))
        }
        model.settings.settings.pulseEnabled = true
        let choices = model.pickerChoices
        print("Self-test: \(choices.count) picker choices: \(choices.map { "\($0.key.map(String.init) ?? "-") \($0.target.fullName)" }.joined(separator: " | "))")
        expect(choices.count >= 2, "at least two browsers/profiles are installed")
        guard choices.count >= 2 else { return finish() }
        model.rules.save(RulesFile())

        // 1. No rule → picker opens next to the pointer.
        let a = URL(string: "https://selftest-a.example/path?q=1")!
        model.route(RouteRequest(url: a, sourceBundleID: "com.apple.mail"))
        await settle()
        expect(model.drop.isVisible, "picker is visible when no rule matches")
        let pointer = model.drop.lastPointer
        expect(model.drop.frame.contains(pointer), "picker opens under the pointer (pointer \(pointer), window \(model.drop.frame))")

        // 2. Number key chooses that target.
        await press("2", keyCode: 19)
        expect(launched.last?.1 == choices[1].id && launched.last?.0 == a, "key 2 opens choice 2 (\(choices[1].target.fullName))")
        expect(!model.drop.isVisible, "picker closes after a choice")

        // 3. Arrows + Return.
        model.route(RouteRequest(url: a))
        await settle()
        // The tile under the pointer is selected by hover, so start from the current selection.
        let start = model.drop.state.selected
        let next = (start + 1) % choices.count
        await press("", keyCode: 124) // →
        await press("\r", keyCode: 36)
        expect(launched.last?.1 == choices[next].id, "→ then Return moves from choice \(start + 1) and opens choice \(next + 1)")

        // 4. Esc cancels without opening.
        let before = launched.count
        model.route(RouteRequest(url: a))
        await settle()
        await press("\u{1b}", keyCode: 53)
        expect(launched.count == before && !model.drop.isVisible, "Esc closes the picker and opens nothing")

        // 5. ⌥ + number = private window.
        model.route(RouteRequest(url: a))
        await settle()
        await press("1", keyCode: 18, flags: .option)
        let privateExpected = choices[0].target.family.supportsPrivate
        expect(launched.last?.2.privateWindow == privateExpected, "⌥1 asks for a private window when \(choices[0].target.appName) supports it (\(privateExpected))")

        // 6. Tab + key = "Always open here" saves a Domain rule; the next link routes without the picker.
        model.route(RouteRequest(url: URL(string: "https://www.selftest-b.example/x")!))
        await settle()
        await press("\t", keyCode: 48)
        await press("2", keyCode: 19)
        let saved = model.rules.file.rules.last
        expect(saved?.conditions == [Condition(.domain, "selftest-b.example")] && saved?.target == choices[1].id,
               "Tab + 2 saved rule “domain selftest-b.example → \(choices[1].target.fullName)”")
        let onDisk = (try? RulesCodec.decode(Data(contentsOf: AppPaths.rulesFile)))?.rules.count
        expect(onDisk == 1, "rule was written to rules.json")
        let n = launched.count
        model.route(RouteRequest(url: URL(string: "https://docs.selftest-b.example/y")!))
        await settle(0.6)
        expect(!model.drop.isVisible && launched.count == n + 1 && launched.last?.1 == choices[1].id, "subdomain link routes by the new rule, no picker")

        // 7. Override key forces the picker even when a rule matches.
        model.route(RouteRequest(url: URL(string: "https://selftest-b.example/")!, modifiers: .option))
        await settle()
        expect(model.drop.isVisible, "⌥ held forces the picker")
        await press("\u{1b}", keyCode: 53)

        // 8. Several links queue up in one picker.
        model.route(RouteRequest(url: URL(string: "https://selftest-c.example/1")!))
        model.route(RouteRequest(url: URL(string: "https://selftest-c.example/2")!))
        await settle()
        expect(model.pickerQueue.count == 2, "two links are queued")
        await press("1", keyCode: 18)
        expect(launched.last?.0.path == "/1" && model.drop.isVisible && model.pickerQueue.count == 1, "first link opens, picker stays for the second")
        await press("\u{1b}", keyCode: 53)
        expect(!model.drop.isVisible && model.pickerQueue.isEmpty, "Esc on the last queued link closes the picker")

        // 9. Broken target → picker with a note.
        model.rules.update { $0.rules.insert(Rule(name: "gone", conditions: [Condition(.domain, "selftest-d.example")], target: TargetID(app: "com.example.not-installed")), at: 0) }
        model.route(RouteRequest(url: URL(string: "https://selftest-d.example")!))
        await settle()
        expect(model.drop.isVisible && model.pickerQueue.first?.note?.contains("isn't installed") == true, "missing target shows the picker with a note")
        await press("\u{1b}", keyCode: 53)

        // 10. bro:// command URL.
        let m = launched.count
        model.handle(urls: [URL(string: "bro://open?url=https%3A%2F%2Fdocs.selftest-b.example%2Fz")!], sourceBundleID: nil, modifiers: [])
        await settle(0.6)
        expect(launched.count == m + 1 && launched.last?.0.absoluteString == "https://docs.selftest-b.example/z", "bro://open?url= routes the inner link")

        // 11. Presets: every pack becomes one rule; adding them again updates, never duplicates.
        let workT = choices[0].id, personalT = choices[1].id
        let packs = Presets.all.map { PresetChoice(pack: $0, target: $0.side == .work ? workT : personalT) }
        let ruleCount = model.rules.file.rules.count
        model.applyPresets(packs)
        model.applyPresets(packs)
        let presetRules = model.rules.file.rules.filter { $0.preset != nil }
        expect(model.rules.file.rules.count == ruleCount + Presets.all.count && presetRules.count == Presets.all.count
               && model.rules.file.rules.first?.preset == "work-apps",
               "\(Presets.all.count) preset packs added twice → \(presetRules.count) rules, “From work apps” first")
        let p = launched.count
        model.route(RouteRequest(url: URL(string: "https://youtu.be/selftest")!, sourceBundleID: "com.tinyspeck.slackmacgap"))
        await settle(0.6)
        model.route(RouteRequest(url: URL(string: "https://youtu.be/selftest")!))
        await settle(0.6)
        expect(launched.count == p + 2 && launched[p].1 == workT && launched[p + 1].1 == personalT,
               "YouTube from Slack → work target (From work apps); YouTube from elsewhere → personal target (Media)")

        // 12. Invalid rules file keeps the last good rules.
        let good = model.rules.file.rules.count
        try? Data("{ not json".utf8).write(to: AppPaths.rulesFile)
        await settle(1.0)
        expect(model.rules.loadError != nil && model.rules.file.rules.count == good, "broken rules.json is rejected; last good rules stay (\(model.rules.loadError ?? "no error"))")

        finish()
    }

    private func finish() {
        print(failures == 0 ? "Self-test PASSED (\(checks) checks)" : "Self-test FAILED: \(failures) of \(checks) checks")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }

    private func expect(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(what)")
        fflush(stdout)
    }

    private func settle(_ seconds: Double = 0.45) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Posts a real key event into the app's event queue, so it goes through the picker's key monitor.
    private func press(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: model.drop.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        await settle(0.35)
    }
}
