import AppKit
import Network
import RoutingCore

/// Chrome bridge (prototype). Chrome is the default browser. The BrowserBro extension in each Chrome
/// profile reports links that came from outside Chrome; BrowserBro answers "keep" or "close" and opens
/// the link in the right profile. See extension/.
@MainActor
final class ChromeBridge {
    static let port: UInt16 = 41417
    static let chromeID = "com.google.Chrome"

    private unowned let model: AppModel
    private var server: BridgeServer?
    /// Extension install → the Chrome profile it lives in. Learned from BrowserBro's own launches.
    private var installs: [String: TargetID] = [:]
    /// Links BrowserBro opened in Chrome a moment ago. The extension reports them too, and they must stay.
    private var launches: [(url: String, target: TargetID, at: Date)] = []
    /// Loop breaker: how often a link was moved in the last seconds.
    private var moves: [String: (count: Int, at: Date)] = [:]
    /// Why the last request got its answer (for the log).
    private var why = ""

    private static var file: URL { AppPaths.supportDir.appending(path: "bridge.json") }

    init(model: AppModel) {
        self.model = model
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([String: TargetID].self, from: data) {
            installs = saved
        }
    }

    /// At least one Chrome profile has the extension and has talked to BrowserBro.
    var isPaired: Bool { !installs.isEmpty }

    func start() {
        guard server == nil else { return }
        do {
            server = try BridgeServer(port: Self.port) { [weak self] req, reply in
                Task { @MainActor in
                    guard let self else { reply(503, Data("{}".utf8)); return }
                    let (status, body) = await self.respond(to: req)
                    reply(status, body)
                }
            }
            Log.app.info("Chrome bridge listening on 127.0.0.1:\(Self.port, privacy: .public)")
        } catch {
            Log.app.error("Chrome bridge did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Call before BrowserBro opens a link, so the extension's report about it is recognised.
    func noteLaunch(_ url: URL, target: TargetID) {
        guard target.app == Self.chromeID else { return }
        prune()
        launches.append((Self.key(url.absoluteString), target, Date()))
    }

    static func currentModifiers() -> ModifierSet {
        let flags = NSEvent.modifierFlags
        var m: ModifierSet = []
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    // MARK: Requests

    private func respond(to req: BridgeServer.Request) async -> (Int, Data) {
        func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8) }
        switch (req.method, req.path) {
        case ("GET", "/ping"):
            return (200, json(["app": "BrowserBro", "paired": installs.count]))
        case ("POST", "/route"):
            // Only the extension may ask: a web page cannot send a chrome-extension:// origin.
            guard req.headers["origin"]?.hasPrefix("chrome-extension://") == true,
                  let object = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let url = object["url"] as? String, let install = object["install"] as? String else {
                return (400, json(["error": "bad request"]))
            }
            let cold = object["cold"] as? Bool ?? false
            let action = await handle(url: url, committed: object["committed"] as? String, install: install,
                                      coldVisit: cold ? (object["visitTime"] as? Double ?? 0) : nil)
            // Persisted (notice) so a failed hand-over can be read back with `log show`. Host only, no full URL.
            Log.route.notice("Bridge: \(cold ? "start-up scan" : "live", privacy: .public) \(object["transition"] as? String ?? "-", privacy: .public) \(URL(string: url)?.host() ?? "?", privacy: .public) → \(action, privacy: .public) (\(self.why, privacy: .public))")
            return (200, json(["action": action]))
        case ("POST", "/hello"):
            let object = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
            let install = String((object?["install"] as? String ?? "?").prefix(8))
            Log.app.notice("Bridge: extension \(object?["version"] as? String ?? "?", privacy: .public) started in a Chrome profile (install \(install, privacy: .public), profile known: \(self.installs[object?["install"] as? String ?? ""] != nil, privacy: .public))")
            return (200, json(["ok": true]))
        default:
            return (404, json(["error": "not found"]))
        }
    }

    /// "keep" = leave the tab where Chrome opened it. "close" = BrowserBro opens the link elsewhere.
    /// `coldVisit`: set for a tab found by the extension's start-up scan (time of its history visit, ms since 1970).
    private func handle(url urlString: String, committed: String?, install: String, coldVisit: Double?) async -> String {
        prune()
        let keys = [urlString, committed].compactMap { $0 }.map(Self.key)
        // BrowserBro opened this link itself: it is where it should be. This also tells us the install's profile.
        if let i = launches.firstIndex(where: { keys.contains($0.url) }) {
            let hit = launches.remove(at: i)
            if hit.target.profile != nil, installs[install] != hit.target {
                installs[install] = hit.target
                try? JSONEncoder().encode(installs).write(to: Self.file, options: .atomic)
            }
            why = "BrowserBro opened it"
            return "keep"
        }
        // Chrome's own pages (home page, start-up pages, new tab page) are not links from outside.
        if !Self.chromeStartPages().isDisjoint(with: keys) { why = "Chrome start page"; return "keep" }
        // Start-up scan: only a tab that this start of Chrome opened, and only right after the start.
        if let coldVisit {
            let started = NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeID).compactMap(\.launchDate).min()
            guard let started, Date().timeIntervalSince(started) < 30,
                  Date(timeIntervalSince1970: coldVisit / 1000) >= started.addingTimeInterval(-2) else {
                why = "not opened by this Chrome start"
                return "keep"
            }
        }
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { why = "not a web link"; return "keep" }
        let key = Self.key(urlString)
        if let m = moves[key], m.count >= 2 {
            why = "moved twice in a row"
            return "keep"
        }
        let stay = await model.routeFromChrome(url, here: installs[install])
        if !stay { moves[key] = ((moves[key]?.count ?? 0) + 1, Date()) }
        why = stay ? (installs[install] == nil ? "rules: stay (profile of this extension not known yet)" : "rules: already in the right profile") : "rules: moved"
        return stay ? "keep" : "close"
    }

    private func prune() {
        let now = Date()
        launches.removeAll { now.timeIntervalSince($0.at) > 30 }
        moves = moves.filter { now.timeIntervalSince($0.value.at) < 15 }
    }

    /// Home page, start-up pages and new tab page that Chrome is set to open by itself (policy or defaults).
    /// Pages a user picks in Chrome's own settings are not read here yet.
    private static func chromeStartPages() -> Set<String> {
        let app = chromeID as CFString
        var pages: Set<String> = []
        for name in ["HomepageLocation", "NewTabPageLocation"] {
            if let page = CFPreferencesCopyAppValue(name as CFString, app) as? String { pages.insert(key(page)) }
        }
        if let list = CFPreferencesCopyAppValue("RestoreOnStartupURLs" as CFString, app) as? [String] {
            for page in list { pages.insert(key(page)) }
        }
        return pages
    }

    /// Chrome rewrites a URL a little (trailing slash, escapes): compare a loose form.
    private static func key(_ string: String) -> String {
        var v = string.removingPercentEncoding ?? string
        if let i = v.firstIndex(of: "#") { v = String(v[..<i]) }
        while v.hasSuffix("/") { v.removeLast() }
        return v.lowercased()
    }
}

/// Fires once: the picker answer and the timeout race for the same continuation.
@MainActor
final class BridgeOnce {
    private var fired = false
    func fire() -> Bool {
        if fired { return false }
        fired = true
        return true
    }
}

/// Tiny HTTP server on 127.0.0.1 for the Chrome extension. One request per connection.
final class BridgeServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    typealias Reply = @Sendable (Int, Data) -> Void
    typealias Handler = @Sendable (Request, @escaping Reply) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.sergchil.BrowserBro.bridge")
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: nothing outside this Mac can reach it.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.app.error("Chrome bridge listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.handler(request) { status, body in
                    self.send(connection, status: status, origin: request.headers["origin"], body: body)
                }
            } else if error != nil || isComplete || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int, origin: String?, body: Data) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let origin, origin.hasPrefix("chrome-extension://") { head += "Access-Control-Allow-Origin: \(origin)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// nil = the request is not complete yet.
    private static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers,
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}
