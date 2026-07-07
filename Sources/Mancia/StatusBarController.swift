import AppKit

/// The menu bar status item and its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let provider: LLMProvider
    private let menu = NSMenu()

    private var providerItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var setupHelpItem: NSMenuItem!

    var onEdit: (() -> Void)?
    var onSettings: (() -> Void)?
    var onAbout: (() -> Void)?

    init(provider: LLMProvider) {
        self.provider = provider
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image =
                NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Mancia")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 18, height: 18)
            button.toolTip = "Mancia"
        }
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func buildMenu() {
        let edit = NSMenuItem(
            title: "Edit Selection…", action: #selector(triggerEdit), keyEquivalent: "e")
        edit.keyEquivalentModifierMask = [.control, .option, .command]
        edit.target = self
        menu.addItem(edit)

        providerItem = NSMenuItem(title: "Provider: GitHub Copilot", action: nil, keyEquivalent: "")
        providerItem.isEnabled = false
        menu.addItem(providerItem)

        setupHelpItem = NSMenuItem(
            title: "Set up Copilot…", action: #selector(openSettings), keyEquivalent: "")
        setupHelpItem.target = self
        setupHelpItem.isHidden = true
        menu.addItem(setupHelpItem)

        menu.addItem(.separator())

        accessibilityItem = NSMenuItem(
            title: "Accessibility permission…", action: #selector(openAccessibility),
            keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: "About", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        accessibilityItem.isHidden = Permissions.isAccessibilityTrusted
        providerItem.title = "Provider: GitHub Copilot"
        Task {
            let status = await provider.checkAvailability()
            providerItem.title = "Provider: GitHub Copilot — \(status.label) \(status.menuMark)"
            switch status {
            case .ready:
                setupHelpItem.isHidden = true
            case .notFound:
                setupHelpItem.title = "Install Copilot CLI…"
                setupHelpItem.isHidden = false
            case .error:
                setupHelpItem.title = "Fix Copilot setup…"
                setupHelpItem.isHidden = false
            }
        }
    }

    // MARK: - Actions

    @objc private func triggerEdit() { onEdit?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func openAbout() { onAbout?() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
}
