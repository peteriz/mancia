# Architecture

AI-Edit is a small `@MainActor`-heavy AppKit/SwiftUI app built with Swift
Package Manager. There's no Xcode project — `Package.swift` defines a single
executable target, `Makefile` and `scripts/make_app.sh` turn the built binary
into a real `.app` bundle.

## Component map

```
Sources/AIEdit/
├── main.swift                    NSApplication bootstrap; routes to DebugCLI
│                                 before any UI is created (LSUIElement, no Dock icon)
├── AppDelegate.swift             Wires status item, hotkey, coordinator, settings window
├── StatusBarController.swift     NSStatusItem + menu (Edit / Provider status / Settings / Quit)
├── HotkeyManager.swift           Registers the global hotkey (KeyboardShortcuts pkg)
├── Permissions.swift             AXIsProcessTrusted() checks + System Settings deep link
├── SelectionCapture.swift        Pasteboard snapshot/capture/replace via synthetic ⌘C/⌘A/⌘V
├── EditCoordinator.swift         Orchestrates capture → panel → provider → apply
├── DebugCLI.swift                --provider-check / --complete headless entry points
├── Actions.swift                 EditAction enum + PromptBuilder (prompt templates)
├── Panel/
│   ├── PanelModel.swift          @Observable state shared between coordinator and view
│   ├── EditPanel.swift           NSPanel host (floating, non-activating, positions near cursor)
│   └── EditPanelView.swift       SwiftUI content (scope picker, actions, result/error states)
├── Providers/
│   ├── LLMProvider.swift         LLMProvider protocol, ProviderStatus, ProviderRegistry
│   └── CopilotCLIProvider.swift  GitHub Copilot CLI backend (binary discovery, argv, Process)
└── Settings/
    ├── AppSettings.swift         @Observable, UserDefaults-backed settings + launch-at-login
    └── SettingsView.swift        SwiftUI settings window content

Tests/AIEditTests/AIEditTests.swift   Prompt templates, argv construction, post-processing,
                                      binary discovery order (all pure, no process spawning)

Support/Info.plist                   LSUIElement=true, bundle id io.github.peteriz.ai-edit
scripts/make_app.sh                  swift build -c release → build/AI-Edit.app, ad-hoc codesign
```

There is no `Resources/` asset catalog — the menu bar icon is the SF Symbol
`wand.and.stars`, set directly on the status item's `NSStatusBarButton`.

## Core flow

`AppDelegate.applicationDidFinishLaunching` builds one `ProviderRegistry`, one
`EditCoordinator`, one `StatusBarController`, and one `HotkeyManager`, all
wired to call `coordinator.start()`.

1. **Trigger** — `HotkeyManager` (global hotkey) or `StatusBarController`
   ("Edit Selection…") calls `EditCoordinator.start()`.
2. **Capture** — `EditCoordinator.start()` first checks Accessibility
   (`Permissions.isAccessibilityTrusted`; prompts + shows an alert if not
   granted, then bails). It then calls
   `SelectionCapture.captureSelection()`, which:
   - Remembers the frontmost app (`NSWorkspace.shared.frontmostApplication`).
   - Snapshots the pasteboard (`PasteboardSnapshot.capture()`).
   - Posts a synthetic `⌘C` (`CGEvent`) and polls `NSPasteboard.changeCount`
     every 30 ms up to 600 ms.
   - Restores the snapshot immediately, returning the captured string (or
     `nil` if nothing changed, i.e. no selection).
3. **Panel** — the result seeds `PanelModel` (`hasSelection`, `charCount`),
   and `EditPanel.show()` positions an `NSPanel` near the mouse (clamped to
   the containing screen), `.nonactivatingPanel` + `.floating` so the target
   app keeps focus.
4. **Perform** — the user picks a built-in `EditAction` or types a free-form
   instruction (`PanelModel.submitInstruction()` → `.custom(text)`).
   `EditCoordinator.perform(_:)`:
   - Resolves input text: for `.document` scope it calls
     `SelectionCapture.captureEntireDocument(from:)` (activates the target
     app, posts `⌘A`, then captures via `⌘C` again); for `.selection` scope
     it reuses the already-captured text.
   - Builds the prompt with `PromptBuilder.build(action:text:targetLanguage:)`.
   - Calls `provider.complete(prompt)` inside a cancellable `Task`, updating
     `PanelModel.phase` (`.running` → `.result` or `.error`).
5. **Apply/Copy/Retry/Cancel** — all wired from `PanelModel` closures back
   into `EditCoordinator`:
   - **Apply** → `SelectionCapture.apply(text:to:entireDocument:)`: puts the
     result on the pasteboard, activates the target app, waits ~150 ms, posts
     `⌘A`+`⌘V` (document scope) or just `⌘V` (selection scope), waits ~1 s,
     then restores the user's original pasteboard snapshot.
   - **Copy** → puts the result directly on the pasteboard and closes.
   - **Retry** → re-runs `perform(lastAction)`.
   - **Cancel** → cancels the in-flight `Task` and closes the panel.

Esc anywhere in the panel routes through `KeyablePanel.cancelOperation` →
`model.onCancel`.

## The `LLMProvider` protocol and adding a provider

```swift
// Sources/AIEdit/Providers/LLMProvider.swift
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func complete(_ prompt: String) async throws -> String
    func checkAvailability() async -> ProviderStatus   // .ready / .notFound / .error(String)
}
```

`ProviderRegistry` holds an array of providers; `current` is simply
`providers.first` — today that's the single `CopilotCLIProvider` instance
built by `ProviderRegistry.makeDefault(settings:)`.

To add a new provider:

1. Create `Sources/AIEdit/Providers/<Name>Provider.swift` conforming to
   `LLMProvider`. Model it on `CopilotCLIProvider`: keep argv/parsing logic in
   `static` functions so it's unit-testable without spawning a process (see
   `CopilotCLIProvider.arguments`, `.resolveExecutable`, `.postProcess`).
2. Surface configuration in `AppSettings` (`Sources/AIEdit/Settings/AppSettings.swift`)
   if the provider needs its own path/model/API-key fields — follow the
   `copilotPath`/`copilotModel` pattern (`UserDefaults`-backed, `didSet`
   persists).
3. Add it to the array in `ProviderRegistry.makeDefault(settings:)`. Since
   `current` is `providers.first`, decide the selection strategy at that
   point (a real picker would need to replace `.first` with a stored
   selection, e.g. an `AppSettings.selectedProviderID`).
4. Add a picker entry in `SettingsView` (`Sources/AIEdit/Settings/SettingsView.swift`)
   — it currently renders a disabled single-entry `Picker` plus a "More
   providers coming soon" footnote; that's the placeholder to replace.
5. Add unit tests alongside the existing ones in
   `Tests/AIEditTests/AIEditTests.swift` for prompt/argv construction and
   output post-processing.

No other call site needs to change — `EditCoordinator`, `DebugCLI`, and
`StatusBarController` all go through `registry.current` /
`provider.complete(_:)` / `provider.checkAvailability()`.

## Permissions model

Two permissions matter, both handled in `Permissions.swift`:

- **Accessibility** — required to post synthetic `⌘C`/`⌘A`/`⌘V` (`CGEvent`).
  Checked via `AXIsProcessTrusted()`; requested via
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
  `EditCoordinator.ensureAccessibility()` gates `start()` on this and shows an
  explanatory `NSAlert` with a button that deep-links to
  `x-apple.systempreferences:...Privacy_Accessibility`
  (`Permissions.openAccessibilitySettings()`). The same deep link backs the
  "Accessibility permission…" menu item, which `StatusBarController` hides
  once trusted.
- **No App Sandbox** — the app needs to spawn the `copilot` process and post
  CGEvents system-wide, both of which are incompatible with the sandbox, so
  `Support/Info.plist` ships without sandbox entitlements.

`Info.plist` also sets `LSUIElement = true` (no Dock icon/app switcher
presence — this is a menu-bar-only app) and bundle id
`io.github.peteriz.ai-edit`.

## Build system

- **Package.swift** — swift-tools 6.0, `.macOS(.v14)`, one executable target
  `AIEdit` (depends on `sindresorhus/KeyboardShortcuts`), one test target
  `AIEditTests`.
- **Makefile** — `build` (`swift build`), `test` (`swift test`), `app`
  (`scripts/make_app.sh`), `run` (`app` + `open build/AI-Edit.app`), `clean`
  (`swift package clean` + `rm -rf build`).
- **scripts/make_app.sh** — `swift build -c release`, assembles
  `build/AI-Edit.app/Contents/{MacOS,Resources}`, copies the binary and
  `Support/Info.plist`, writes a `PkgInfo`, then
  `codesign --force --deep -s - build/AI-Edit.app` (ad-hoc signature — no
  Developer ID). Because the signature/binary changes on every rebuild,
  Accessibility must be re-granted each time (macOS ties the grant to the
  binary's identity).

## Debug/E2E hooks

`main.swift` checks `DebugCLI.handle(CommandLine.arguments)` before touching
`NSApplication` at all, so these run headless (no UI, no Accessibility
prompt):

- `AIEdit --provider-check` — builds the default registry, calls
  `provider.checkAvailability()`, prints `"<displayName>: ready"` (exit 0),
  `"...: not found"` (exit 1), or `"...: error — <message>"` (exit 1).
- `AIEdit --complete <action> <<< "text"` — reads stdin as the input text,
  parses `<action>` via `EditAction.parse` (`rewrite | summarize |
  fix-grammar | translate | reply | custom:<instruction>`; unknown values
  exit 2), builds the prompt with `PromptBuilder.build`, calls
  `provider.complete(prompt)`, prints the result (exit 0) or an error to
  stderr (exit 1).

Both run the async body on the main actor via a small `Task { @MainActor in
... }` + `dispatchMain()` shim (`DebugCLI.run`), since there's no
`NSApplication` run loop to drive the actor hops. These flags are the
intended way to exercise the real provider pipeline in CI without simulating
UI or keystrokes.
