import Foundation
import Testing
@testable import RoutingCore

// MARK: - Helpers

func req(_ s: String, from: String? = nil, _ mods: ModifierSet = []) -> RouteRequest {
    RouteRequest(url: URL(string: s)!, sourceBundleID: from, modifiers: mods)
}

func rule(_ name: String = "r", _ mode: MatchMode = .any, _ conds: [Condition], to app: String = "com.apple.Safari",
          profile: String? = nil, enabled: Bool = true) -> Rule {
    Rule(name: name, enabled: enabled, mode: mode, conditions: conds, target: TargetID(app: app, profile: profile))
}

func matches(_ c: Condition, _ r: RouteRequest) -> Bool {
    RoutingEngine.ruleMatches(rule("t", .all, [c]), r)
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

// MARK: - Conditions

@Suite("Conditions")
struct ConditionTests {
    @Test("domain uses a dot boundary", arguments: [
        ("https://example.com", true),
        ("https://docs.example.com/a", true),
        ("https://a.b.example.com", true),
        ("https://notexample.com", false),
        ("https://example.com.evil.net", false),
        ("https://EXAMPLE.COM./x", true),
        ("https://example.com:8443/x", true),
    ])
    func domain(url: String, expected: Bool) {
        #expect(matches(Condition(.domain, "example.com"), req(url)) == expected)
    }

    @Test("domain input is cleaned")
    func domainInput() {
        for v in ["Example.com", "*.example.com", ".example.com", "https://example.com/path", "example.com:80"] {
            #expect(matches(Condition(.domain, v), req("https://docs.example.com")), "value \(v)")
        }
    }

    @Test("Unicode domains match their punycode form")
    func idn() {
        #expect(matches(Condition(.domain, "bücher.de"), req("https://www.xn--bcher-kva.de/")))
        #expect(matches(Condition(.domain, "xn--bcher-kva.de"), RouteRequest(url: URL(string: "https://www.bücher.de/")!)))
        #expect(Punycode.encode("bücher") == "bcher-kva")
        #expect(Punycode.encode("münchen") == "mnchen-3ya")
        #expect(Punycode.encode("пример") == "e1afmkfd")
        #expect(HostNormalizer.normalize("Пример.РФ") == "xn--e1afmkfd.xn--p1ai")
    }

    @Test func hostIs() {
        #expect(matches(Condition(.hostIs, "www.example.com"), req("https://WWW.example.com/x")))
        #expect(!matches(Condition(.hostIs, "example.com"), req("https://www.example.com/x")))
    }

    @Test func pathPrefix() {
        #expect(matches(Condition(.pathPrefix, "/work/"), req("https://a.com/work/x")))
        #expect(matches(Condition(.pathPrefix, "work"), req("https://a.com/work/x")))
        #expect(!matches(Condition(.pathPrefix, "/Work/"), req("https://a.com/work/x")), "path is case-sensitive")
        #expect(matches(Condition(.pathPrefix, "/"), req("https://a.com")), "empty path counts as /")
        #expect(matches(Condition(.pathPrefix, "/a b"), req("https://a.com/a%20b/c")), "path is decoded")
    }

    @Test func urlContains() {
        #expect(matches(Condition(.urlContains, "Project=Work"), req("https://a.com/?project=work")))
        #expect(!matches(Condition(.urlContains, "home"), req("https://a.com/?project=work")))
    }

    @Test("wildcards", arguments: [
        ("*.github.io", "https://me.github.io/blog", true),
        ("*.github.io", "https://a.b.github.io", false),
        ("**.github.io", "https://a.b.github.io", true),
        ("*.foo.com/bar", "https://x.foo.com/bar", true),
        ("*.foo.com/bar", "https://x.foo.com/bar/baz", false),
        ("*.foo.com/bar**", "https://x.foo.com/bar/baz", true),
        ("*.foo.com/api?id=**", "https://x.foo.com/api?id=7", true),
        ("*.foo.com/api?id=**", "https://x.foo.com/api?x=1", false),
        ("localhost:3000/**", "http://localhost:3000/a", true),
        ("localhost:3000/**", "http://localhost:4000/a", false),
        ("https://*.foo.com/**", "https://x.foo.com/a", true),
        ("https://*.foo.com/**", "http://x.foo.com/a", false),
    ])
    func wildcard(pattern: String, url: String, expected: Bool) {
        #expect(matches(Condition(.wildcard, pattern), req(url)) == expected)
    }

    @Test func regex() {
        #expect(matches(Condition(.regex, "youtube\\.com/watch"), req("https://www.youtube.com/watch?v=1")))
        #expect(!matches(Condition(.regex, "YOUTUBE"), req("https://youtube.com")), "regex is case-sensitive")
        #expect(matches(Condition(.regex, "(?i)YOUTUBE"), req("https://youtube.com")))
    }

    @Test func sourceApp() {
        let c = Condition(.sourceApp, "com.tinyspeck.slackmacgap")
        #expect(matches(c, req("https://a.com", from: "com.tinyspeck.slackmacgap")))
        #expect(matches(c, req("https://a.com", from: "COM.tinyspeck.SLACKMACGAP")))
        #expect(!matches(c, req("https://a.com", from: "com.apple.mail")))
        #expect(!matches(c, req("https://a.com")), "unknown sender never matches")
    }

    @Test func modifier() {
        let c = Condition(.modifier, "shift+command")
        #expect(matches(c, req("https://a.com", [.shift, .command])))
        #expect(matches(c, req("https://a.com", [.shift, .command, .option])))
        #expect(!matches(c, req("https://a.com", [.shift])))
    }

    @Test func negate() {
        #expect(!matches(Condition(.domain, "a.com", negate: true), req("https://a.com")))
        #expect(matches(Condition(.domain, "a.com", negate: true), req("https://b.com")))
    }

    @Test("invalid conditions never match, even when negated", arguments: [
        Condition(.regex, "(unclosed"), Condition(.regex, "(unclosed", negate: true),
        Condition(.domain, " "), Condition(.modifier, "hyper"), Condition(.sourceApp, ""),
    ])
    func invalid(c: Condition) {
        #expect(!matches(c, req("https://a.com")))
    }

    @Test func modifierParsing() {
        #expect(ModifierSet(string: "option+shift") == [.option, .shift])
        #expect(ModifierSet(string: "⌥⇧") == [.option, .shift])
        #expect(ModifierSet(string: "alt, cmd") == [.option, .command])
        #expect(ModifierSet(string: "") == [])
        #expect(ModifierSet(string: "hyper") == nil)
    }
}

// MARK: - Decisions

@Suite("Decisions")
struct DecisionTests {
    let chrome = TargetID(app: "com.google.Chrome", profile: "Profile 3")

    @Test func allAndAny() {
        let all = rule("all", .all, [Condition(.domain, "a.com"), Condition(.sourceApp, "x")])
        #expect(RoutingEngine.ruleMatches(all, req("https://a.com", from: "x")))
        #expect(!RoutingEngine.ruleMatches(all, req("https://a.com", from: "y")))
        var any = all; any.mode = .any
        #expect(RoutingEngine.ruleMatches(any, req("https://a.com", from: "y")))
        #expect(!RoutingEngine.ruleMatches(any, req("https://b.com", from: "y")))
    }

    @Test func firstMatchWins() {
        let file = RulesFile(rules: [
            rule("first", .any, [Condition(.domain, "a.com")], to: "one"),
            rule("second", .any, [Condition(.domain, "a.com")], to: "two"),
        ])
        #expect(RoutingEngine.decide(req("https://a.com"), rules: CompiledRules(file)) == .open(TargetID(app: "one"), TargetOptions(), ruleID: file.rules[0].id))
    }

    @Test func disabledRulesAreSkipped() {
        let file = RulesFile(rules: [
            rule("off", .any, [], to: "one", enabled: false),
            rule("on", .any, [Condition(.domain, "a.com")], to: "two"),
        ])
        #expect(RoutingEngine.decide(req("https://a.com"), rules: CompiledRules(file)) == .open(TargetID(app: "two"), TargetOptions(), ruleID: file.rules[1].id))
    }

    @Test func emptyRuleIsCatchAll() {
        let file = RulesFile(rules: [rule("all", .all, [], to: "one")])
        if case .open(let t, _, _) = RoutingEngine.decide(req("https://anything.example"), rules: CompiledRules(file)) {
            #expect(t.app == "one")
        } else { Issue.record("expected open") }
    }

    @Test func overrideModifierForcesPicker() {
        let file = RulesFile(pickerOverrideModifier: .option, rules: [rule("all", .all, [], to: "one")])
        #expect(RoutingEngine.decide(req("https://a.com", [.option]), rules: CompiledRules(file)) == .showPicker(.override))
        var off = file; off.pickerOverrideModifier = []
        if case .open = RoutingEngine.decide(req("https://a.com", [.option]), rules: CompiledRules(off)) {} else { Issue.record("expected open when override is off") }
    }

    @Test func fallbackModes() {
        var file = RulesFile(fallback: .picker)
        #expect(RoutingEngine.decide(req("https://a.com"), rules: CompiledRules(file)) == .showPicker(.noMatch))
        file.fallback = .defaultTarget
        #expect(RoutingEngine.decide(req("https://a.com"), rules: CompiledRules(file)) == .showPicker(.noDefaultTarget))
        file.defaultTarget = chrome
        #expect(RoutingEngine.decide(req("https://a.com"), rules: CompiledRules(file)) == .open(chrome, TargetOptions(), ruleID: nil))
        #expect(RoutingEngine.decide(req("https://a.com"), rules: CompiledRules(file), available: []) == .showPicker(.noDefaultTarget))
    }

    @Test func brokenTargetShowsPicker() {
        let r = rule("r", .any, [Condition(.domain, "a.com")], to: "gone")
        let file = RulesFile(rules: [r])
        #expect(RoutingEngine.decide(req("https://a.com"), rules: CompiledRules(file), available: [chrome]) == .showPicker(.brokenTarget(ruleID: r.id)))
    }

    @Test func traceExplainsEachRule() {
        let file = RulesFile(rules: [
            rule("work", .any, [Condition(.domain, "linear.app")], to: "one"),
            rule("google", .any, [Condition(.domain, "google.com")], to: "two"),
        ])
        let t = RoutingEngine.trace(req("https://docs.google.com"), rules: CompiledRules(file))
        #expect(t.rules.map(\.matched) == [false, true])
        #expect(t.winningRuleID == file.rules[1].id)
        #expect(t.rules[0].explanation.contains("linear.app"))
    }

    @Test("decide stays well under 1 ms with 200 rules")
    func performance() {
        var rules: [Rule] = (0..<199).map { i in
            rule("r\(i)", .all, [Condition(.domain, "site\(i).example"), Condition(.pathPrefix, "/p\(i)"),
                                 Condition(.regex, "q=\(i)$")], to: "app\(i)")
        }
        rules.append(rule("last", .any, [Condition(.domain, "target.example")], to: "winner"))
        let compiled = CompiledRules(RulesFile(rules: rules))
        let r = req("https://www.target.example/x?q=1", from: "com.apple.mail")
        var samples: [Duration] = []
        let clock = ContinuousClock()
        // Average over small batches so a single scheduler hiccup (tests run in parallel) doesn't count as a slow decision.
        for _ in 0..<100 {
            let batch = clock.measure { for _ in 0..<20 { _ = RoutingEngine.decide(r, rules: compiled) } }
            samples.append(batch / 20)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p99 = samples[Int(Double(samples.count) * 0.99)]
        print("decide() with 200 rules: p50 = \(p50), p99 = \(p99)")
        // p50 is asserted because tests run in parallel and p99 then measures the scheduler, not the engine.
        // Run `swift test -c release --filter performance` alone to check the p99 budget.
        #expect(p50 < .milliseconds(1), "p50 = \(p50)")
    }
}

// MARK: - Conflicts

@Suite("Conflicts")
struct ConflictTests {
    func kinds(_ rules: [Rule]) -> [RuleWarning.Kind] {
        ConflictAnalyzer.analyze(RulesFile(rules: rules)).map(\.kind)
    }

    @Test func coveredByBroaderDomain() {
        let a = rule("google", .any, [Condition(.domain, "google.com")], to: "one")
        let b = rule("docs", .any, [Condition(.domain, "docs.google.com")], to: "two")
        #expect(kinds([a, b]) == [.coveredBy(ruleID: a.id, sameTarget: false)])
        #expect(kinds([b, a]).isEmpty, "narrow rule first is fine")
    }

    @Test func allModeCoveredWhenOneConditionImpliesEarlierAny() {
        let a = rule("slack", .any, [Condition(.sourceApp, "com.slack")], to: "one")
        let b = rule("slack linear", .all, [Condition(.sourceApp, "com.slack"), Condition(.domain, "linear.app")], to: "two")
        #expect(kinds([a, b]) == [.coveredBy(ruleID: a.id, sameTarget: false)])
    }

    @Test func anyModeNeedsEveryBranchCovered() {
        let a = rule("a", .any, [Condition(.domain, "a.com")], to: "one")
        let b = rule("b", .any, [Condition(.domain, "x.a.com"), Condition(.domain, "b.com")], to: "two")
        #expect(kinds([a, b]).isEmpty)
    }

    @Test func duplicateConditionsDifferentTarget() {
        let a = rule("a", .any, [Condition(.domain, "a.com")], to: "one")
        let b = rule("b", .any, [Condition(.domain, "A.com")], to: "two")
        #expect(kinds([a, b]) == [.duplicateConditions(ruleID: a.id)])
    }

    @Test func catchAllCoversLaterRules() {
        let a = rule("all", .any, [], to: "one")
        let b = rule("b", .any, [Condition(.domain, "b.com")], to: "two")
        #expect(kinds([a, b]) == [.coveredBy(ruleID: a.id, sameTarget: false)])
    }

    @Test func disabledEarlierRuleDoesNotCover() {
        let a = rule("all", .any, [], to: "one", enabled: false)
        let b = rule("b", .any, [Condition(.domain, "b.com")], to: "two")
        #expect(kinds([a, b]).isEmpty)
    }

    @Test func negationContrapositive() {
        let a = rule("not docs", .all, [Condition(.domain, "docs.a.com", negate: true)], to: "one")
        let b = rule("not a", .all, [Condition(.domain, "a.com", negate: true)], to: "two")
        // NOT a.com ⇒ NOT docs.a.com, so b is covered by a.
        #expect(kinds([a, b]) == [.coveredBy(ruleID: a.id, sameTarget: false)])
    }

    @Test func invalidRegexIsAnError() {
        let r = rule("bad", .any, [Condition(.regex, "(")], to: "one")
        let w = ConflictAnalyzer.analyze(RulesFile(rules: [r]))
        #expect(w.count == 1 && w[0].isError)
    }

    @Test func missingTarget() {
        let r = rule("r", .any, [Condition(.domain, "a.com")], to: "gone")
        let w = ConflictAnalyzer.analyze(RulesFile(rules: [r]), available: [TargetID(app: "here")])
        #expect(w.map(\.kind) == [.missingTarget])
    }
}

// MARK: - Codec and corpus

@Suite("Codec")
struct CodecTests {
    @Test func roundTrip() throws {
        let file = try RulesCodec.decode(try fixture("rules.json"))
        #expect(file.rules.count == 10)
        let again = try RulesCodec.decode(RulesCodec.encode(file))
        #expect(again == file)
    }

    @Test func defaultsForMissingFields() throws {
        let file = try RulesCodec.decode(Data(#"{"rules":[{"match":{"conditions":[]},"target":{"app":"x"}}]}"#.utf8))
        #expect(file.fallback == .picker)
        #expect(file.pickerOverrideModifier == .option)
        #expect(file.rules[0].enabled && file.rules[0].mode == .any && file.rules[0].name == "Untitled rule")
    }

    @Test func syntaxErrorHasLocation() {
        #expect {
            _ = try RulesCodec.decode(Data("{\n \"rules\": [ }".utf8))
        } throws: { error in
            (error as? RulesFileError)?.message.contains("line") == true
        }
    }

    @Test func unknownConditionTypeIsReported() {
        let json = #"{"rules":[{"match":{"conditions":[{"type":"magic","value":"x"}]},"target":{"app":"x"}}]}"#
        #expect {
            _ = try RulesCodec.decode(Data(json.utf8))
        } throws: { error in
            let m = (error as? RulesFileError)?.message ?? ""
            return m.contains("magic") && m.contains("rules[0]")
        }
    }

    @Test func newerSchemaIsRejected() {
        #expect(throws: RulesFileError.self) { _ = try RulesCodec.decode(Data(#"{"schemaVersion": 99}"#.utf8)) }
    }

    @Test func emptyProfileBecomesNil() throws {
        let file = try RulesCodec.decode(Data(#"{"rules":[{"match":{"conditions":[]},"target":{"app":"x","profile":""}}]}"#.utf8))
        #expect(file.rules[0].target.profile == nil)
    }
}

@Suite("Corpus")
struct CorpusTests {
    struct Case: Decodable { let url: String; let from: String?; let modifiers: String?; let expect: String }

    @Test("every corpus case routes as the independent oracle expects")
    func corpus() throws {
        let compiled = CompiledRules(try RulesCodec.decode(try fixture("rules.json")))
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("corpus.json"))
        #expect(cases.count >= 200)
        var failures: [String] = []
        for c in cases {
            let r = RouteRequest(url: URL(string: c.url)!, sourceBundleID: c.from, modifiers: ModifierSet(string: c.modifiers ?? "") ?? [])
            let got: String
            switch RoutingEngine.decide(r, rules: compiled) {
            case .open(let t, _, _): got = t.description
            case .showPicker: got = "picker"
            }
            if got != c.expect { failures.append("\(c.url) from \(c.from ?? "-") \(c.modifiers ?? "-"): want \(c.expect), got \(got)") }
        }
        #expect(failures.isEmpty, "\(failures.count) failures:\n\(failures.prefix(20).joined(separator: "\n"))")
    }
}
