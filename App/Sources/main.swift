import AppKit

// Data files are private (ARCHITECTURE §15): directories 0700, files 0600.
umask(0o077)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar app (LSUIElement)
app.run()
