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
        if let launchOverride { try await launchOverride(url, target, options) } else { try await Launcher.open(url, in: target, options: options) }
    }

    @ObservationIgnored lazy var drop = DropController(model: self)
    @ObservationIgnored lazy var pulse = PulseController(model: self)

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
            var note: String?
            if case .brokenTarget(let rid) = reason, let r = rules.file.rules.first(where: { $0.id == rid }) {
                note = "Rule “\(r.name)” points to a browser or profile that isn't installed."
            }
            if case .noDefaultTarget = reason { note = "No default target is set. Pick one in Settings → General." }
            showPicker(PickerItem(request: req, reason: reason, note: note))
        }
    }

    func showPicker(_ item: PickerItem) {
        guard !pickerChoices.isEmpty else {
            // Never lose a link: with no targets at all, hand it to the previous default browser.
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
        Task {
            do {
                try await self.launch(req.url, in: choice.target, options: TargetOptions(privateWindow: privateWindow && choice.target.family.supportsPrivate))
                self.remember(req, target: choice.target, ruleName: nil)
            } catch {
                self.pickerQueue.insert(PickerItem(request: req, reason: item.reason, note: error.localizedDescription), at: 0)
                self.drop.present()
            }
        }
        if pickerQueue.isEmpty { drop.dismiss() } else { drop.present() }
    }

    func cancelPicker() {
        guard !pickerQueue.isEmpty else { return }
        pickerQueue.removeFirst()
        if pickerQueue.isEmpty { drop.dismiss() } else { drop.present() }
    }

    func cancelAllPickers() {
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

    func refreshDefaultStatus() {
        isDefaultBrowser = SystemIntegration.isDefaultBrowser
    }
}
