import AppKit
import OSLog
import RoutingCore

enum Log {
    static let app = Logger(subsystem: "com.sergchil.BrowserBro", category: "app")
    static let route = Logger(subsystem: "com.sergchil.BrowserBro", category: "route")
    static let signposter = OSSignposter(subsystem: "com.sergchil.BrowserBro", category: .pointsOfInterest)
}

struct LaunchError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Opens a URL in a browser, with a profile and private mode when the browser supports them.
@MainActor
enum Launcher {
    static func arguments(for target: BrowserTarget, url: URL, options: TargetOptions) -> [String] {
        var args: [String] = []
        switch target.family {
        case .chromium:
            if let dir = target.launchProfile { args.append("--profile-directory=\(dir)") }
            if options.privateWindow { args.append("--incognito") }
        case .gecko:
            if let path = target.launchProfile { args += ["--profile", path] }
            if options.privateWindow { args.append("--private-window") }
        case .arc, .safari, .other:
            // Arc ignores flags, and a second Arc instance started with arguments breaks: never pass any.
            break
        }
        guard !args.isEmpty else { return [] }
        return args + [url.absoluteString]
    }

    static func open(_ url: URL, in target: BrowserTarget, options: TargetOptions) async throws {
        guard target.id.app != Bundle.main.bundleIdentifier else { throw LaunchError(message: "Refusing to open a link in BrowserBro itself.") }
        let state = Log.signposter.beginInterval("launch", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("launch", state) }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = !options.openInBackground
        let args = arguments(for: target, url: url, options: options)
        do {
            if target.family == .arc, let spaceID = target.launchProfile {
                try await ArcSpaces.open(url, spaceID: spaceID, app: target, activate: !options.openInBackground)
            } else if args.isEmpty {
                try await NSWorkspace.shared.open([url], withApplicationAt: target.appURL, configuration: config)
            } else {
                // A running browser ignores arguments, so start a short-lived second instance: Chromium and Firefox
                // hand the command line to the running instance (or start the requested profile) and exit.
                let running = !NSRunningApplication.runningApplications(withBundleIdentifier: target.id.app).isEmpty
                config.arguments = args
                config.createsNewApplicationInstance = running
                try await NSWorkspace.shared.openApplication(at: target.appURL, configuration: config)
            }
            Log.route.info("Opened \(url.absoluteString, privacy: .private) in \(target.id.description, privacy: .public)")
        } catch {
            Log.route.error("Launch failed for \(target.id.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw LaunchError(message: "Couldn't open in \(target.fullName): \(error.localizedDescription)")
        }
    }

    /// Last resort when nothing else works: the browser that was default before BrowserBro.
    static func openWithFallbackBrowser(_ url: URL, previousDefault: String?) {
        let candidates = [previousDefault, "/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"].compactMap { $0 }
        for path in candidates where FileManager.default.fileExists(atPath: path) && !path.contains("BrowserBro") {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        Log.route.fault("No fallback browser found")
    }
}

/// Opens a link in an Arc profile: focus the Space bound to that profile, then make a new tab in it.
/// Arc has no command-line way to pick a profile; AppleScript (Automation permission) is the only one.
enum ArcSpaces {
    /// One serial queue: NSAppleScript is not thread-safe, and this keeps it off the main thread.
    private static let queue = DispatchQueue(label: "com.sergchil.BrowserBro.arc-script")

    @MainActor
    static func open(_ url: URL, spaceID: String, app: BrowserTarget, activate: Bool) async throws {
        if NSRunningApplication.runningApplications(withBundleIdentifier: app.id.app).isEmpty {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = activate
            try await NSWorkspace.shared.openApplication(at: app.appURL, configuration: config)
            try await waitUntilResponds()
        }
        let result = try await run(script(url: url, spaceID: spaceID, activate: activate))
        if result == "space not found" {
            throw LaunchError(message: "Arc has no Space for this profile in its main window.")
        }
    }

    /// Arc answers Apple Events a moment after launch; ask for the window count until it does (max ~10 s).
    private static func waitUntilResponds() async throws {
        var lastError: Error?
        for _ in 0..<40 {
            do {
                _ = try await run("tell application id \"\(KnownBrowsers.arc)\" to count of windows")
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError ?? LaunchError(message: "Arc didn't respond after launch.")
    }

    /// Index access only: Arc rejects variable or `whose` references to spaces (error -1700).
    static func script(url: URL, spaceID: String, activate: Bool) -> String {
        """
        tell application id "\(KnownBrowsers.arc)"
          if (count of windows) is 0 then make new window
          set targetSpaceID to "\(escape(spaceID))"
          set idx to 0
          repeat with i from 1 to (count of spaces of window 1)
            if (id of space i of window 1) is targetSpaceID then set idx to i
          end repeat
          if idx is 0 then return "space not found"
          tell space idx of window 1 to focus
          delay 0.3
          tell space idx of window 1 to make new tab with properties {URL:"\(escape(url.absoluteString))"}
          \(activate ? "activate" : "")
          return "ok"
        end tell
        """
    }

    /// Escapes a value for an AppleScript string literal.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                    let number = error[NSAppleScript.errorNumber] as? Int ?? 0
                    cont.resume(throwing: LaunchError(message: "\(message) (\(number))"))
                } else {
                    cont.resume(returning: output?.stringValue ?? "")
                }
            }
        }
    }
}
