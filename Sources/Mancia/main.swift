import AppKit

// Debug/E2E hooks run headless and exit before any UI is created.
if DebugCLI.handle(CommandLine.arguments) {
    // handle() calls dispatchMain(); control never returns here.
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only (LSUIElement)
app.run()
