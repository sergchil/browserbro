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
        case .safari, .other:
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
            if args.isEmpty {
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
