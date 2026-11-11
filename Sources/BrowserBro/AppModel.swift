import AppKit
import RoutingCore

struct PickerChoice: Identifiable, Hashable {
    let target: BrowserTarget
    let title: String
    let subtitle: String?
    let key: Int?
    var id: TargetID { target.id }
}

struct PickerItem: Identifiable, Equatable {
    let id = UUID()
    let request: RouteRequest
    let reason: PickerReason
    var note: String?
}

struct RecentRoute: Identifiable {
    let id = UUID()
    let request: RouteRequest
    let target: BrowserTarget
    let ruleName: String?
    let date = Date()
}

/// The app's state and the routing glue: request → decision → launch or picker.
@MainActor
@Observable
final class AppModel {
    let catalog = BrowserCatalog()
    let rules = RuleStore()
    let settings = SettingsStore()

    private(set) var recent: [RecentRoute] = []
    private(set) var pickerQueue: [PickerItem] = []
    var isDefaultBrowser = SystemIntegration.isDefaultBrowser
    var settingsPane: SettingsPane = .general
    var selectedRuleID: UUID?

    /// Replaces the real launch in the self-test, so no browser opens.
    @ObservationIgnored var launchOverride: ((URL, BrowserTarget, TargetOptions) async throws -> Void)?

    func launch(_ url: URL, in target: BrowserTarget, options: TargetOptions) async throws {
        bridge.noteLaunch(url, target: target.id)
        if let launchOverride { try await launchOverride(url, target, options) } else { try await Launcher.open(url, in: target, options: options) }
    }

    @ObservationIgnored lazy var drop = DropController(model: self)
    @ObservationIgnored lazy var pulse = PulseController(model: self)
    @ObservationIgnored lazy var bridge = ChromeBridge(model: self)
    /// Chrome bridge: called when the picker item is chosen (or cancelled, choice = nil).
    /// Returns true when the link is already open in the chosen profile, so nothing is launched.
    @ObservationIgnored private var pickerHooks: [UUID: (PickerChoice?, Bool) -> Bool] = [:]

    // MARK: Picker choices

    /// Visible targets in the user's order, with number keys 1–9.
    var pickerChoices: [PickerChoice] {
        let s = settings.settings
        let visible = catalog.targets.filter { settings.isVisible($0) }
        let ordered = visible.enumerated().sorted { a, b in
            let ia = s.targetOrder.firstIndex(of: a.element.id.description) ?? (10_000 + a.offset)
            let ib = s.targetOrder.firstIndex(of: b.element.id.description) ?? (10_000 + b.offset)
            return ia < ib
        }.map(\.element)
        let custom = Set(s.customKeys.values)
        var next = 1
        return ordered.map { t in
            var key = s.customKeys[t.id.description]
            if key == nil {
                while custom.contains(next) { next += 1 }
                if next <= 9 { key = next; next += 1 }
            }
            if let label = s.customLabels[t.id.description] {
                return PickerChoice(target: t, title: label, subtitle: t.shortAppName, key: key)
            }
            // Profile first: people pick "Work" or "Personal"; the icon already shows the browser.
            if let profile = t.profileName {
                return PickerChoice(target: t, title: profile, subtitle: t.shortAppName, key: key)
            }
            return PickerChoice(target: t, title: t.shortAppName, subtitle: nil, key: key)
        }
    }

    /// Every target in the user's order, including hidden ones (for Settings).
    var allTargetsOrdered: [BrowserTarget] {
        let order = settings.settings.targetOrder
        return catalog.targets.enumerated().sorted { a, b in
            (order.firstIndex(of: a.element.id.description) ?? (10_000 + a.offset)) < (order.firstIndex(of: b.element.id.description) ?? (10_000 + b.offset))
        }.map(\.element)
    }

    // MARK: Routing

    func handle(urls: [URL], sourceBundleID: String?, modifiers: ModifierSet) {
        for url in urls {
            if url.scheme?.lowercased() == "bro" {
                // bro://open?url=<encoded>
                guard let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                      let target = URL(string: inner), target.scheme != nil else {
                    Log.route.error("Ignored bro:// URL without a valid url parameter")
                    continue
                }
                route(RouteRequest(url: target, sourceBundleID: sourceBundleID, modifiers: modifiers))
            } else {
                route(RouteRequest(url: url, sourceBundleID: sourceBundleID, modifiers: modifiers))
            }
        }
    }

    func route(_ req: RouteRequest) {
        let state = Log.signposter.beginInterval("decide")
        let decision = RoutingEngine.decide(req, rules: rules.compiled, available: catalog.availableIDs)
        Log.signposter.endInterval("decide", state)
        Log.route.info("Link from \(req.sourceBundleID ?? "unknown", privacy: .public) mods \(req.modifiers.description, privacy: .public): \(String(describing: decision), privacy: .public)")

        switch decision {
        case .open(let id, let options, let ruleID):
            guard let target = catalog.target(for: id) else {
                showPicker(PickerItem(request: req, reason: .brokenTarget(ruleID: ruleID ?? UUID()), note: "Target \(id) is missing."))
                return
            }
            let ruleName = ruleID.flatMap { id in rules.file.rules.first { $0.id == id }?.name } ?? "Default target"
            Task {
                do {
                    try await self.launch(req.url, in: target, options: options)
                    self.remember(req, target: target, ruleName: ruleName)
                    if self.settings.settings.pulseEnabled { self.pulse.show(target: target, request: req) }
                } catch {
                    self.showPicker(PickerItem(request: req, reason: .noMatch, note: error.localizedDescription))
                }
            }
        case .showPicker(let reason):
            showPicker(pickerItem(req, reason))
        }
    }

    private func pickerItem(_ req: RouteRequest, _ reason: PickerReason) -> PickerItem {
        var note: String?
        if case .brokenTarget(let rid) = reason, let r = rules.file.rules.first(where: { $0.id == rid }) {
            note = "Rule “\(r.name)” points to a browser or profile that isn't installed."
        }
        if case .noDefaultTarget = reason { note = "No default target is set. Pick one in Settings → General." }
        return PickerItem(request: req, reason: reason, note: note)
    }

    /// Chrome bridge: Chrome already opened this link in the profile `here` (nil = not known yet).
    /// Returns true when the tab should stay where it is; false when BrowserBro opens the link elsewhere.
    func routeFromChrome(_ url: URL, here: TargetID?) async -> Bool {
        let req = RouteRequest(url: url, sourceBundleID: nil, modifiers: ChromeBridge.currentModifiers())
        let decision = RoutingEngine.decide(req, rules: rules.compiled, available: catalog.availableIDs)
        Log.route.info("Link from the Chrome bridge: \(String(describing: decision), privacy: .public)")
        switch decision {
        case .open(let id, let options, _):
            // Already in the right place: the same profile, or "Chrome, any profile".
            let anyChromeProfile = id.app == ChromeBridge.chromeID && id.profile == nil
            if (id == here || anyChromeProfile) && !options.privateWindow { return true }
            route(req)
            return false
        case .showPicker(let reason):
            guard !pickerChoices.isEmpty else { return true }
            let item = pickerItem(req, reason)
            let once = BridgeOnce()
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                pickerHooks[item.id] = { choice, privateWindow in
                    // Cancelled, or picked the profile the tab is already in: keep the tab.
                    let stay = choice == nil || (choice?.target.id == here && !privateWindow)
                    if once.fire() { continuation.resume(returning: stay) }
                    return stay
                }
                showPicker(item)
                // The extension cannot wait for ever: after 25 s the tab stays, the picker stays open.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(25))
                    if once.fire() { continuation.resume(returning: true) }
                }
            }
        }
    }

    func showPicker(_ item: PickerItem) {
        guard !pickerChoices.isEmpty else {
            // Never lose a link: with no targets at all, hand it to the previous default browser.
            if DemoMode.isOn {
                // Demo mode never opens a browser, not even the fallback one.
                print("Demo: would open \(item.request.url.absoluteString) in the fallback browser")
                fflush(stdout)
                return
            }
            Launcher.openWithFallbackBrowser(item.request.url, previousDefault: settings.settings.previousDefaultBrowser)
            return
        }
        pickerQueue.append(item)
        drop.present()
    }

    /// Called by the picker.
    func choose(_ choice: PickerChoice, privateWindow: Bool, alwaysHere: Bool) {
        guard let item = pickerQueue.first else { return }
        pickerQueue.removeFirst()
        let req = item.request
        if alwaysHere { saveSiteRule(for: req, target: choice.target.id) }
        if let hook = pickerHooks.removeValue(forKey: item.id), hook(choice, privateWindow) {
            // Chrome bridge: the link is already open in this profile.
            remember(req, target: choice.target, ruleName: nil)
        } else {
            Task {
                do {
                    try await self.launch(req.url, in: choice.target, options: TargetOptions(privateWindow: privateWindow && choice.target.family.supportsPrivate))
                    self.remember(req, target: choice.target, ruleName: nil)
                } catch {
                    self.pickerQueue.insert(PickerItem(request: req, reason: item.reason, note: error.localizedDescription), at: 0)
                    self.drop.present()
                }
            }
        }
        if pickerQueue.isEmpty { drop.dismiss() } else { drop.present() }
    }

    func cancelPicker() {
        guard !pickerQueue.isEmpty else { return }
        let item = pickerQueue.removeFirst()
        _ = pickerHooks.removeValue(forKey: item.id)?(nil, false)
        if pickerQueue.isEmpty { drop.dismiss() } else { drop.present() }
    }

    func cancelAllPickers() {
        for item in pickerQueue { _ = pickerHooks.removeValue(forKey: item.id)?(nil, false) }
        pickerQueue.removeAll()
        drop.dismiss()
    }

    /// "Open elsewhere": show the picker for a link that was already routed.
    func reopen(_ req: RouteRequest) {
        showPicker(PickerItem(request: req, reason: .override, note: nil))
    }

    private func remember(_ req: RouteRequest, target: BrowserTarget, ruleName: String?) {
        recent.insert(RecentRoute(request: req, target: target, ruleName: ruleName), at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
    }

    /// "Always open <domain> here": appends a Domain rule.
    private func saveSiteRule(for req: RouteRequest, target: TargetID) {
        let domain = HostNormalizer.siteDomain(of: req.url)
        guard !domain.isEmpty else { return }
        let rule = Rule(name: domain, mode: .any, conditions: [Condition(.domain, domain)], target: target)
        rules.update { $0.rules.append(rule) }
        if let w = rules.warnings(available: catalog.availableIDs).first(where: { $0.ruleID == rule.id }) {
            Log.app.notice("New site rule has a warning: \(w.message, privacy: .public)")
            pulse.showMessage("Saved rule for \(domain), but: \(w.message)")
        }
    }

    // MARK: Presets

    /// The preset sheet is open (Settings window).
    var presetSheetVisible = false

    /// First run: offer presets once, only while there are no rules yet.
    /// Call it after the Settings window is on screen: a sheet presented in the same tick
    /// the window appears can leave the wrong pane behind it.
    func offerPresetsIfNew() {
        guard !settings.settings.presetsOffered else { return }
        if rules.file.rules.isEmpty {
            settingsPane = .rules
            presetSheetVisible = true
        } else {
            settings.settings.presetsOffered = true
        }
    }

    /// Visible targets in picker order, labelled by the user's label or the profile name (for the target guess).
    var presetCandidates: [(id: TargetID, label: String)] {
        pickerChoices.map { c in
            (c.id, settings.settings.customLabels[c.id.description] ?? c.target.profileName ?? "")
        }
    }

    /// Adds or updates one rule per chosen pack.
    func applyPresets(_ choices: [PresetChoice]) {
        guard !choices.isEmpty else { return }
        rules.update { $0 = Presets.apply(choices, to: $0) }
        Log.app.info("Added presets: \(choices.map(\.pack.id).joined(separator: ", "), privacy: .public)")
    }

    func refreshDefaultStatus() {
        isDefaultBrowser = SystemIntegration.isDefaultBrowser
    }
}
