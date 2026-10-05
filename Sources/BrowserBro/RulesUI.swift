import AppKit
import RoutingCore
import SwiftUI

// MARK: - Rules list

struct RulesPane: View {
    @Bindable var model: AppModel

    var body: some View {
        let file = model.rules.file
        let warnings = model.rules.warnings(available: model.catalog.availableIDs)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selectedRuleID) {
                    ForEach(Array(file.rules.enumerated()), id: \.element.id) { idx, rule in
                        RuleRow(model: model, rule: rule, index: idx + 1, warnings: warnings.filter { $0.ruleID == rule.id })
                            .tag(rule.id)
                            .contextMenu {
                                Button("Duplicate") { duplicate(rule) }
                                Button("Delete", role: .destructive) { delete(rule.id) }
                            }
                    }
                    .onMove { from, to in model.rules.update { $0.rules.move(fromOffsets: from, toOffset: to) } }
                }
                .listStyle(.inset)
                .overlay {
                    if file.rules.isEmpty {
                        ContentUnavailableView("No rules yet", systemImage: "arrow.triangle.branch",
                                               description: Text("Add a rule, or tick “Always open … here” in the picker."))
                    }
                }
                Divider()
                Text("First match wins. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(width: 300)
            Divider()

            Group {
                if let id = model.selectedRuleID, file.rules.contains(where: { $0.id == id }) {
                    RuleEditor(model: model, ruleID: id, warnings: warnings.filter { $0.ruleID == id })
                        .id(id)
                } else {
                    ContentUnavailableView("Select a rule", systemImage: "sidebar.left")
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItemGroup {
                Button { add() } label: { Label("Add Rule", systemImage: "plus") }
                    .help("Add rule")
                Button { if let id = model.selectedRuleID { delete(id) } } label: { Label("Delete Rule", systemImage: "minus") }
                    .disabled(model.selectedRuleID == nil)
                    .help("Delete rule")
            }
        }
    }

    private func add() {
        let target = model.pickerChoices.first?.id ?? TargetID(app: "com.apple.Safari")
        let rule = Rule(name: "New rule", mode: .any, conditions: [Condition(.domain, "")], target: target)
        model.rules.update { $0.rules.append(rule) }
        model.selectedRuleID = rule.id
    }

    private func duplicate(_ rule: Rule) {
        var copy = rule
        copy.id = UUID()
        copy.name += " copy"
        model.rules.update { f in
            let i = f.rules.firstIndex { $0.id == rule.id } ?? f.rules.count - 1
            f.rules.insert(copy, at: i + 1)
        }
        model.selectedRuleID = copy.id
    }

    private func delete(_ id: UUID) {
        model.rules.update { $0.rules.removeAll { $0.id == id } }
        if model.selectedRuleID == id { model.selectedRuleID = nil }
    }
}

private struct RuleRow: View {
    let model: AppModel
    let rule: Rule
    let index: Int
    let warnings: [RuleWarning]

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
            if let t = model.catalog.target(for: rule.target) {
                TargetIcon(target: t, size: 22)
            } else {
                Image(systemName: "questionmark.app.dashed").frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let w = warnings.first {
                Image(systemName: w.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .help(w.message)
            }
            Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { v in
                model.rules.update { f in if let i = f.rules.firstIndex(where: { $0.id == rule.id }) { f.rules[i].enabled = v } }
            }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private var summary: String {
        let target = model.catalog.target(for: rule.target)?.fullName ?? rule.target.description
        if rule.conditions.isEmpty { return "every link → \(target)" }
        let joiner = rule.mode == .all ? " and " : " or "
        return rule.conditions.map(\.summary).joined(separator: joiner) + " → " + target
    }
}

// MARK: - Rule editor

struct RuleEditor: View {
    @Bindable var model: AppModel
    let ruleID: UUID
    let warnings: [RuleWarning]
    @State private var tryURL = ""
    @State private var pickingAppFor: Int?

    private var rule: Binding<Rule> {
        Binding(
            get: { model.rules.file.rules.first { $0.id == ruleID } ?? Rule(name: "", conditions: [], target: TargetID(app: "")) },
            set: { new in model.rules.update { f in if let i = f.rules.firstIndex(where: { $0.id == ruleID }) { f.rules[i] = new } } })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: rule.name)
                Toggle("Enabled", isOn: rule.enabled)
            }

            Section {
                Picker("When", selection: rule.mode) {
                    Text("all of these match").tag(MatchMode.all)
                    Text("any of these match").tag(MatchMode.any)
                }
                ForEach(rule.wrappedValue.conditions.indices, id: \.self) { i in
                    ConditionRow(condition: Binding(
                        get: { rule.wrappedValue.conditions.indices.contains(i) ? rule.wrappedValue.conditions[i] : Condition(.domain, "") },
                        set: { rule.wrappedValue.conditions[i] = $0 }),
                                 onPickApp: { pickingAppFor = i },
                                 onRemove: { rule.wrappedValue.conditions.remove(at: i) })
                }
                Button { rule.wrappedValue.conditions.append(Condition(.domain, "")) } label: { Label("Add condition", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                if rule.wrappedValue.conditions.isEmpty {
                    Label("No conditions: this rule matches every link.", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor).font(.callout)
                }
            } header: {
                Text("Conditions")
            }

            Section("Open in") {
                TargetMenu(model: model, label: "Browser", selection: Binding(get: { rule.wrappedValue.target }, set: { if let v = $0 { rule.wrappedValue.target = v } }))
                let supportsPrivate = model.catalog.target(for: rule.wrappedValue.target)?.family.supportsPrivate ?? false
                Toggle("Private window", isOn: rule.options.privateWindow)
                    .disabled(!supportsPrivate)
                    .help(supportsPrivate ? "" : "This browser can't be asked for a private window.")
                Toggle("Open in background", isOn: rule.options.openInBackground)
            }

            if !warnings.isEmpty {
                Section {
                    ForEach(warnings) { w in
                        Label(w.message, systemImage: w.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }

            Section("Try a link") {
                TextField("https://…", text: $tryURL)
                if let url = URL(string: tryURL), url.scheme != nil {
                    let ok = RoutingEngine.ruleMatches(rule.wrappedValue, RouteRequest(url: url))
                    Label(ok ? "This rule matches (sender unknown, no keys held)." : "This rule does not match.",
                          systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
                        .symbolRenderingMode(ok ? .multicolor : .monochrome)
                        .foregroundStyle(ok ? .primary : .secondary)
                    Text("Use the Tester to check a sender app, keys, and rule order.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { pickingAppFor != nil }, set: { if !$0 { pickingAppFor = nil } })) {
            AppPickerSheet { bundleID in
                if let i = pickingAppFor, rule.wrappedValue.conditions.indices.contains(i) {
                    rule.wrappedValue.conditions[i].value = bundleID
                }
                pickingAppFor = nil
            }
        }
    }
}

private struct ConditionRow: View {
    @Binding var condition: Condition
    let onPickApp: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Type", selection: $condition.kind) {
                ForEach(ConditionKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .help(condition.kind.help)

            switch condition.kind {
            case .sourceApp:
                HStack(spacing: 6) {
                    if let icon = AppIcons.icon(bundleID: condition.value) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    TextField("Bundle ID", text: $condition.value, prompt: Text(condition.kind.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                    Button("Choose…", action: onPickApp)
                }
            case .modifier:
                ModifierToggles(value: $condition.value)
                Spacer()
            default:
                TextField("Value", text: $condition.value, prompt: Text(condition.kind.placeholder))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .font(condition.kind == .regex || condition.kind == .wildcard ? .body.monospaced() : .body)
            }

            Toggle("NOT", isOn: $condition.negate)
                .toggleStyle(.button)
                .help("Invert this condition")
            Button(role: .destructive, action: onRemove) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove condition")
        }
        .labelsHidden()
    }
}

private struct ModifierToggles: View {
    @Binding var value: String

    var body: some View {
        let set = ModifierSet(string: value) ?? []
        HStack(spacing: 4) {
            ForEach(ModifierSet.all, id: \.1) { m in
                Toggle(m.2, isOn: Binding(get: { set.contains(m.0) }, set: { on in
                    var s = set
                    if on { s.insert(m.0) } else { s.remove(m.0) }
                    value = s.name
                }))
                .toggleStyle(.button)
                .help(m.1)
            }
        }
    }
}

// MARK: - App picker

struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

@MainActor
enum InstalledApps {
    static var cache: [InstalledApp]?

    static func all() -> [InstalledApp] {
        if let cache { return cache }
        let fm = FileManager.default
        var roots = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"].map { URL(fileURLWithPath: $0) }
        roots.append(fm.homeDirectoryForCurrentUser.appending(path: "Applications"))
        var seen: Set<String> = []
        var apps: [InstalledApp] = []
        func add(_ url: URL) {
            guard url.pathExtension == "app", let b = Bundle(url: url), let id = b.bundleIdentifier, !seen.contains(id) else { return }
            seen.insert(id)
            apps.append(InstalledApp(bundleID: id, name: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url: url))
        }
        for root in roots {
            for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if url.pathExtension == "app" { add(url) }
                else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for inner in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { add(inner) }
                }
            }
        }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            if let u = running.bundleURL { add(u) }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache = apps
        return apps
    }
}

struct AppPickerSheet: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?

    var body: some View {
        let apps = InstalledApps.all().filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        VStack(spacing: 0) {
            TextField("Search apps by name or bundle ID", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { if let first = selection ?? apps.first?.bundleID { onPick(first) } }
            List(apps, selection: $selection) { app in
                HStack {
                    Image(nsImage: AppIcons.icon(for: app.url)).resizable().frame(width: 22, height: 22)
                    Text(app.name)
                    Spacer()
                    Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .tag(app.bundleID)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onPick(app.bundleID) }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose") { if let s = selection { onPick(s) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Tester

struct TesterPane: View {
    @Bindable var model: AppModel
    @State private var urlText = "https://"
    @State private var source = ""
    @State private var mods: ModifierSet = []
    @State private var picking = false

    var body: some View {
        let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme != nil && $0.host() != nil ? $0 : nil }
        Form {
            Section("Link") {
                TextField("URL", text: $urlText).font(.body.monospaced())
                HStack {
                    if let icon = AppIcons.icon(bundleID: source.isEmpty ? nil : source) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    TextField("Clicked in (bundle ID)", text: $source, prompt: Text("unknown sender"))
                    Button("Choose…") { picking = true }
                }
                HStack {
                    Text("Keys held")
                    Spacer()
                    ModifierToggles(value: Binding(get: { mods.name }, set: { mods = ModifierSet(string: $0) ?? [] }))
                }
            }
            if let url {
                let trace = RoutingEngine.trace(RouteRequest(url: url, sourceBundleID: source.isEmpty ? nil : source, modifiers: mods),
                                                rules: model.rules.compiled, available: model.catalog.availableIDs)
                Section("Result") {
                    resultView(trace)
                }
                Section("Trace") {
                    if trace.overrideHeld {
                        Label("Override keys held: rules are skipped.", systemImage: "hand.raised").foregroundStyle(.secondary)
                    }
                    ForEach(trace.rules) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(r.index)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                            Image(systemName: !r.enabled ? "minus.circle" : (r.matched ? "checkmark.circle.fill" : "xmark.circle"))
                                .symbolRenderingMode(r.enabled && r.matched ? .multicolor : .monochrome)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).fontWeight(r.ruleID == trace.winningRuleID ? .semibold : .regular)
                                Text(r.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.ruleID == trace.winningRuleID { Text("winner").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                        }
                    }
                    if trace.rules.isEmpty { Text("No rules yet.").foregroundStyle(.secondary) }
                }
            } else {
                Section { Text("Type a full URL, like https://linear.app/team/issue/1").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tester")
        .sheet(isPresented: $picking) {
            AppPickerSheet { source = $0; picking = false }
        }
    }

    @ViewBuilder
    private func resultView(_ trace: Trace) -> some View {
        switch trace.decision {
        case .open(let id, let options, let ruleID):
            let target = model.catalog.target(for: id)
            HStack(spacing: 10) {
                if let target { TargetIcon(target: target, size: 30) }
                VStack(alignment: .leading) {
                    Text("Opens in \(target?.fullName ?? id.description)").font(.headline)
                    Text(ruleID.flatMap { id in model.rules.file.rules.first { $0.id == id }.map { "Rule “\($0.name)”" } } ?? "Default target")
                        .foregroundStyle(.secondary)
                    if options.privateWindow || options.openInBackground {
                        Text([options.privateWindow ? "private window" : nil, options.openInBackground ? "in background" : nil].compactMap { $0 }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .showPicker(let reason):
            Label {
                switch reason {
                case .noMatch: Text("Shows the picker: no rule matches.")
                case .override: Text("Shows the picker: override keys are held.")
                case .brokenTarget: Text("Shows the picker: the matching rule's browser or profile is missing.")
                case .noDefaultTarget: Text("Shows the picker: no default target is set.")
                }
            } icon: { Image(systemName: "rectangle.grid.1x2") }
                .font(.headline)
        }
    }
}
