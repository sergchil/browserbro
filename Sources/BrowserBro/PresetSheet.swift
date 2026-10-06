import RoutingCore
import SwiftUI

/// "Start with presets?": tick a pack, pick where it opens, and it becomes one normal rule.
/// Shown once on first run (no rules yet) and from Rules → "Add from Preset…".
struct PresetSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct RowState {
        var on = false
        var target: TargetID?
        var filter = ""
    }

    @State private var rows: [String: RowState] = [:]
    @State private var firstRun = false

    var body: some View {
        let file = model.rules.file
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(firstRun ? "Start with presets?" : "Add from preset").font(.title2.weight(.semibold))
                Text("Each pack you tick becomes one rule. You can edit or delete it later.")
                    .foregroundStyle(.secondary)
            }

            BBGlassContainer {
                VStack(spacing: 8) {
                    ForEach(Presets.all) { pack in
                        row(pack, added: Presets.existingRule(for: pack, in: file) != nil)
                    }
                }
            }

            HStack {
                Text("From work apps goes first: the app you clicked in wins over the site.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(firstRun ? "Skip" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .bbGlassButtonStyle(prominent: false)
                Button(addTitle(file)) { add() }
                    .keyboardShortcut(.defaultAction)
                    .bbGlassButtonStyle(prominent: true)
                    .disabled(chosen.isEmpty || chosen.contains { rows[$0.id]?.target == nil })
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: setUp)
    }

    @ViewBuilder
    private func row(_ pack: PresetPack, added: Bool) -> some View {
        let state = Binding(get: { rows[pack.id] ?? RowState() }, set: { rows[pack.id] = $0 })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: state.on) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(pack.name).font(.body.weight(.medium))
                            if added {
                                Text("Added").font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.tint.opacity(0.18), in: Capsule())
                                    .help("This pack is already a rule. Tick it to update that rule.")
                            }
                        }
                        Text(pack.summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                TargetMenu(model: model, label: "Opens in", selection: Binding(
                    get: { state.wrappedValue.target },
                    set: { v in
                        state.wrappedValue.target = v
                        if v != nil { state.wrappedValue.on = true } // picking a target is a choice
                    }), allowNone: true, noneTitle: "Choose…")
                    .labelsHidden()
                    .frame(width: 210)
            }
            if pack.takesPathFilter && state.wrappedValue.on {
                HStack(spacing: 8) {
                    Text("Only this org or path").font(.callout)
                    TextField("Org", text: state.filter, prompt: Text("acme (empty = whole site)"))
                        .textFieldStyle(.roundedBorder)
                    Text(filterExample(state.wrappedValue.filter)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.leading, 24)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bbGlass(cornerRadius: 12)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: state.wrappedValue.on)
    }

    private var chosen: [PresetPack] { Presets.all.filter { rows[$0.id]?.on == true } }

    private func addTitle(_ file: RulesFile) -> String {
        let updates = chosen.filter { Presets.existingRule(for: $0, in: file) != nil }.count
        let adds = chosen.count - updates
        func n(_ k: Int) -> String { k == 1 ? "1 rule" : "\(k) rules" }
        switch (adds, updates) {
        case (_, 0): return "Add \(n(adds))"
        case (0, _): return "Update \(n(updates))"
        default: return "Add \(adds), update \(updates)"
        }
    }

    private func filterExample(_ raw: String) -> String {
        let f = Presets.cleanPathFilter(raw)
        return f.isEmpty ? "github.com/…" : "github.com/\(f)/…"
    }

    private func setUp() {
        firstRun = !model.settings.settings.presetsOffered
        let candidates = model.presetCandidates
        for pack in Presets.all {
            if let existing = Presets.existingRule(for: pack, in: model.rules.file) {
                rows[pack.id] = RowState(on: false, target: existing.target, filter: Presets.pathFilter(of: existing))
            } else {
                rows[pack.id] = RowState(on: DemoMode.presetTicks?.contains(pack.id) ?? false,
                                         target: Presets.guessTarget(for: pack.side, among: candidates))
            }
        }
    }

    private func add() {
        let choices = chosen.compactMap { pack -> PresetChoice? in
            guard let s = rows[pack.id], let target = s.target else { return nil }
            return PresetChoice(pack: pack, target: target, pathFilter: s.filter)
        }
        model.applyPresets(choices)
        model.settings.settings.presetsOffered = true
        model.selectedRuleID = nil
        model.settingsPane = .rules
        dismiss()
    }
}
