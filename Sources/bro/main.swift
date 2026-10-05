import Foundation
import RoutingCore

// bro — command-line tester for BrowserBro rules.
//
//   bro test <url> [--from <bundleID>] [--option] [--shift] [--command] [--control] [--rules <path>]
//   bro check [--rules <path>]
//   bro corpus <corpus.json> [--rules <path>]

let defaultRulesPath = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/BrowserBro/rules.json").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bro: \(message)\n".utf8))
    exit(2)
}

func usage() -> Never {
    print("""
    usage:
      bro test <url> [--from <bundleID>] [--option] [--shift] [--command] [--control] [--rules <path>]
      bro check [--rules <path>]
      bro corpus <corpus.json> [--rules <path>]
    default rules file: \(defaultRulesPath)
    """)
    exit(2)
}

func loadRules(_ path: String) -> RulesFile {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    do { return try RulesCodec.decode(data) } catch { fail("\(path): \(error.message)") }
}

func describe(_ d: Decision, rules: RulesFile) -> String {
    switch d {
    case .open(let t, let o, let id):
        let name = id.flatMap { id in rules.rules.firstIndex { $0.id == id }.map { "rule \($0 + 1) “\(rules.rules[$0].name)”" } } ?? "default target"
        var opts: [String] = []
        if o.privateWindow { opts.append("private") }
        if o.openInBackground { opts.append("background") }
        return "\(name) → \(t)\(opts.isEmpty ? "" : " [\(opts.joined(separator: ", "))]")"
    case .showPicker(let reason):
        switch reason {
        case .noMatch: return "picker (no rule matched)"
        case .override: return "picker (override modifier held)"
        case .brokenTarget: return "picker (rule target missing)"
        case .noDefaultTarget: return "picker (no default target set)"
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

@MainActor func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

@MainActor func takeFlag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let rulesPath = takeOption("--rules") ?? defaultRulesPath

switch command {
case "test":
    let from = takeOption("--from")
    var mods: ModifierSet = []
    if takeFlag("--option") { mods.insert(.option) }
    if takeFlag("--shift") { mods.insert(.shift) }
    if takeFlag("--command") { mods.insert(.command) }
    if takeFlag("--control") { mods.insert(.control) }
    guard let raw = args.first, let url = URL(string: raw), url.scheme != nil else { fail("give a full URL, like https://example.com") }
    let file = loadRules(rulesPath)
    let trace = RoutingEngine.trace(RouteRequest(url: url, sourceBundleID: from, modifiers: mods), rules: CompiledRules(file))
    print("\(url.absoluteString)   from \(from ?? "unknown")   modifiers \(mods)")
    print("Decision: \(describe(trace.decision, rules: file))")
    print("Trace:")
    for r in trace.rules {
        let mark = !r.enabled ? "–" : (r.matched ? "✓" : "✗")
        let win = r.ruleID == trace.winningRuleID ? "  ← winner" : ""
        let idx = r.index < 10 ? " \(r.index)" : "\(r.index)"
        print("  \(idx) \(mark) \(r.name): \(r.explanation)\(win)")
    }
    if trace.overrideHeld { print("  (override modifier held: rules skipped)") }

case "check":
    let file = loadRules(rulesPath)
    let warnings = ConflictAnalyzer.analyze(file)
    print("\(file.rules.count) rules, fallback: \(file.fallback.rawValue)")
    if warnings.isEmpty { print("No problems found.") }
    for w in warnings {
        let idx = (file.rules.firstIndex { $0.id == w.ruleID } ?? -1) + 1
        print("  \(w.isError ? "error" : "warning") rule \(idx) “\(file.rules[idx - 1].name)”: \(w.message)")
    }
    exit(warnings.contains { $0.isError } ? 1 : 0)

case "corpus":
    // Corpus format: [{ "url": "...", "from": "bundle.id"?, "modifiers": "option"?, "expect": "app#profile" | "picker" }]
    struct Case: Decodable { let url: String; let from: String?; let modifiers: String?; let expect: String }
    guard let path = args.first, let data = FileManager.default.contents(atPath: path) else { fail("give a corpus file") }
    let cases: [Case]
    do { cases = try JSONDecoder().decode([Case].self, from: data) } catch { fail("corpus: \(error)") }
    let file = loadRules(rulesPath)
    let compiled = CompiledRules(file)
    var failures = 0
    for c in cases {
        guard let url = URL(string: c.url) else { fail("bad URL in corpus: \(c.url)") }
        let req = RouteRequest(url: url, sourceBundleID: c.from, modifiers: ModifierSet(string: c.modifiers ?? "") ?? [])
        let got: String
        switch RoutingEngine.decide(req, rules: compiled) {
        case .open(let t, _, _): got = t.description
        case .showPicker: got = "picker"
        }
        if got != c.expect {
            failures += 1
            print("FAIL \(c.url) from \(c.from ?? "-") mods \(c.modifiers ?? "-"): expected \(c.expect), got \(got)")
        }
    }
    print("\(cases.count - failures)/\(cases.count) passed")
    exit(failures == 0 ? 0 : 1)

default:
    usage()
}
