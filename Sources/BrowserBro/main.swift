import AppKit

// BrowserBro: a menu bar app that becomes the default browser and routes each link
// to the right browser and profile.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
