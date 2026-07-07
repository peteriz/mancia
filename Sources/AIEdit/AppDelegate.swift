import AppKit
import SwiftUI

/// Wires together the status item, global hotkey, and edit coordinator, and
/// owns the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var registry = ProviderRegistry.makeDefault(settings: settings)
    private var coordinator: EditCoordinator?
    private var statusBar: StatusBarController?
    private var hotkey: HotkeyManager?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = EditCoordinator(registry: registry, settings: settings)
        self.coordinator = coordinator

        let statusBar = StatusBarController(registry: registry)
        statusBar.onEdit = { [weak self] in self?.coordinator?.start() }
        statusBar.onSettings = { [weak self] in self?.showSettings() }
        statusBar.onAbout = { [weak self] in self?.showAbout() }
        self.statusBar = statusBar

        self.hotkey = HotkeyManager { [weak self] in self?.coordinator?.start() }
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, registry: registry))
        let window = NSWindow(contentViewController: hosting)
        window.title = "AI-Edit Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "AI-Edit",
            .applicationVersion: "0.1.0",
        ])
    }
}
