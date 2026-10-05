import AppKit
import RoutingCore
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, browsers, rules, tester, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .browsers: "Browsers & Profiles"
        case .rules: "Rules"
        case .tester: "Tester"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .browsers: "macwindow.on.rectangle"
        case .rules: "arrow.triangle.branch"
        case .tester: "checkmark.seal"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { model.settingsPane }, set: { model.settingsPane = $0 ?? .general })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            switch model.settingsPane {
            case .general: GeneralPane(model: model)
            case .browsers: BrowsersPane(model: model)
            case .rules: RulesPane(model: model)
            case .tester: TesterPane(model: model)
            case .about: AboutPane()
            }
        }
        .frame(minWidth: 980, minHeight: 520)
    }
}

// MARK: - General

struct GeneralPane: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = SystemIntegration.launchAtLogin
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Default browser") {
                HStack {
                    Label(model.isDefaultBrowser ? "BrowserBro is your default browser." : "BrowserBro is not your default browser yet.",
                          systemImage: model.isDefaultBrowser ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.isDefaultBrowser ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    Spacer()
                    if model.isDefaultBrowser {
                        if let prev = model.settings.settings.previousDefaultBrowser {
                            Button("Restore \(FileManager.default.displayName(atPath: prev).replacingOccurrences(of: ".app", with: ""))") {
                                Task { await run { try await SystemIntegration.restorePreviousBrowser(settings: model.settings) } }
                            }
                        }
                    } else {
                        Button("Set as Default Browser…") {
                            Task { await run { try await SystemIntegration.becomeDefaultBrowser(settings: model.settings) } }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if let errorText { Text(errorText).foregroundStyle(.red).font(.callout) }
                Text("macOS asks you to confirm. Links you click in any app then come to BrowserBro first.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Routing") {
                Picker("When no rule matches", selection: rulesBinding(\.fallback)) {
                    Text("Show the picker").tag(FallbackKind.picker)
                    Text("Open in the default target").tag(FallbackKind.defaultTarget)
                }
                TargetMenu(model: model, label: "Default target", selection: Binding(
                    get: { model.rules.file.defaultTarget },
                    set: { v in model.rules.update { $0.defaultTarget = v } }), allowNone: true)
                    .disabled(model.rules.file.fallback != .defaultTarget)
                Picker("Hold to always show the picker", selection: rulesBinding(\.pickerOverrideModifier)) {
                    Text("Off").tag(ModifierSet())
                    Text("⌥ Option").tag(ModifierSet.option)
                    Text("⌃ Control").tag(ModifierSet.control)
                    Text("⌘ Command").tag(ModifierSet.command)
                    Text("⇧ Shift").tag(ModifierSet.shift)
                    Text("⌥⇧ Option + Shift").tag(ModifierSet([.option, .shift]))
                }
            }

            Section("Appearance") {
                Toggle("Show where a link went, next to the pointer", isOn: model.settings.binding(\.pulseEnabled))
            }

            Section("System") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        SystemIntegration.launchAtLogin = v
                        launchAtLogin = SystemIntegration.launchAtLogin
                    }
                LabeledContent("Rules file") {
                    HStack {
                        Text(AppPaths.rulesFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.rulesFile]) }
                    }
                }
                if let err = model.rules.loadError {
                    Label("The rules file has an error, so the last good rules are still used: \(err)", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Import Rules…") { importRules() }
                    Button("Export Rules…") { exportRules() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { model.refreshDefaultStatus() }
    }

    private func rulesBinding<V>(_ kp: WritableKeyPath<RulesFile, V>) -> Binding<V> {
        Binding(get: { model.rules.file[keyPath: kp] }, set: { v in model.rules.update { $0[keyPath: kp] = v } })
    }

    private func run(_ op: () async throws -> Void) async {
        do { try await op(); errorText = nil } catch { errorText = error.localizedDescription }
        model.refreshDefaultStatus()
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try RulesCodec.decode(try Data(contentsOf: url))
            model.rules.save(file)
            errorText = nil
        } catch let e as RulesFileError {
            errorText = "Import failed: \(e.message)"
        } catch {
            errorText = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "browserbro-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try RulesCodec.encode(model.rules.file).write(to: url, options: .atomic) } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Target menu

/// Picks a browser or a browser + profile. Also offers "any profile" for profiled browsers.
struct TargetMenu: View {
    let model: AppModel
    let label: String
    @Binding var selection: TargetID?
    var allowNone = false

    var body: some View {
        let targets = model.catalog.targets
        let profiledApps = Dictionary(grouping: targets.filter { $0.profileName != nil }, by: \.id.app)
        Picker(label, selection: $selection) {
            if allowNone { Text("None").tag(TargetID?.none) }
            ForEach(targets) { t in
                Label { Text(t.fullName) } icon: { Image(nsImage: smallIcon(t.appURL)) }
                    .tag(TargetID?.some(t.id))
            }
            if !profiledApps.isEmpty {
                Divider()
                ForEach(profiledApps.keys.sorted(), id: \.self) { app in
                    if let t = model.catalog.appOnlyTarget(TargetID(app: app)) {
                        Text("\(t.appName) (last used profile)").tag(TargetID?.some(t.id))
                    }
                }
            }
            if let s = selection, model.catalog.target(for: s) == nil {
                Divider()
                Text("Missing: \(s.description)").tag(TargetID?.some(s))
            }
        }
    }

    private func smallIcon(_ url: URL) -> NSImage {
        let img = AppIcons.icon(for: url).copy() as! NSImage
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}

// MARK: - Browsers & Profiles

struct BrowsersPane: View {
    @Bindable var model: AppModel

    var body: some View {
        let targets = model.allTargetsOrdered
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section {
                    ForEach(targets) { t in
                        BrowserRow(model: model, target: t)
                    }
                    .onMove { from, to in
                        var ids = targets.map(\.id.description)
                        ids.move(fromOffsets: from, toOffset: to)
                        model.settings.settings.targetOrder = ids
                    }
                } footer: {
                    Text("Drag to change the order in the picker. Hidden items stay usable in rules. Profiles come from each browser's own files and update by themselves.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .navigationTitle("Browsers & Profiles")
        .toolbar {
            Button { model.catalog.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }
}

private struct BrowserRow: View {
    @Bindable var model: AppModel
    let target: BrowserTarget

    var body: some View {
        let key = target.id.description
        HStack(spacing: 12) {
            TargetIcon(target: target, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.appName).font(.body.weight(.medium))
                Text(target.profileName.map { "Profile: \($0)" } ?? familyNote)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 160, alignment: .leading)
            Spacer()
            TextField("Label", text: Binding(
                get: { model.settings.settings.customLabels[key] ?? "" },
                set: { model.settings.settings.customLabels[key] = $0.isEmpty ? nil : $0 }), prompt: Text(target.profileName ?? target.appName))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            Picker("Key", selection: Binding(
                get: { model.settings.settings.customKeys[key] ?? 0 },
                set: { model.settings.settings.customKeys[key] = $0 == 0 ? nil : $0 })) {
                Text("Auto").tag(0)
                ForEach(1...9, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 72)
            Toggle("Show in picker", isOn: Binding(
                get: { model.settings.isVisible(target) },
                set: { model.settings.setVisible(target, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }

    private var familyNote: String {
        switch target.family {
        case .chromium: "Chromium · one profile"
        case .gecko: "Firefox family · one profile"
        case .arc: "Arc · one profile with a Space"
        case .safari: "Safari"
        case .other: target.isKnownBrowser ? "Browser" : "Not a known browser · hidden by default"
        }
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("BrowserBro").font(.largeTitle.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Routes every link to the right browser and profile.\nRuns fully on your Mac: no network calls, no accounts, no analytics.")
                .multilineTextAlignment(.center)
            Text("MIT License").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}
