import AppKit
import SwiftUI

/// Wires together the status item, global hotkey, and edit coordinator, and
/// owns the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var provider = CopilotCLIProvider(settings: settings)
    private var coordinator: EditCoordinator?
    private var statusBar: StatusBarController?
    private var hotkey: HotkeyManager?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = EditCoordinator(provider: provider, settings: settings)
        coordinator.onOpenSettings = { [weak self] in self?.showSettings() }
        self.coordinator = coordinator

        let statusBar = StatusBarController(provider: provider)
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
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, provider: provider))
        // Create the window with its final style mask up front: reassigning
        // styleMask after NSWindow(contentViewController:) collapses the
        // content area to zero height (the "empty settings window" bug).
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mancia Settings"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        window.center()
        // Opening Settings activates the app and takes key status away from
        // the floating panel; without this, an open edit session stops
        // responding to Esc and typing after Settings closes.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.coordinator?.refocusPanel() }
        }
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Mancia",
            .applicationVersion: "0.1.0",
        ]
        if let iconURL = Bundle.main.url(forResource: "mancia-logo", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 128, height: 128)
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
