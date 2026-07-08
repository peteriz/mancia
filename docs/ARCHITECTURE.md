# Architecture

Mancia is a small `@MainActor`-heavy AppKit/SwiftUI app built with Swift
Package Manager. There's no Xcode project — `Package.swift` defines a single
executable target, `Makefile` and `scripts/make_app.sh` turn the built binary
into a real `.app` bundle.

## Component map

```
Sources/Mancia/
├── main.swift                    NSApplication bootstrap; routes to DebugCLI
│                                 before any UI is created (LSUIElement, no Dock icon)
├── AppDelegate.swift             Wires status item, hotkey, coordinator, settings window
├── StatusBarController.swift     NSStatusItem + menu (Edit / Provider status / Settings / Quit)
├── HotkeyManager.swift           Registers the global hotkey (KeyboardShortcuts pkg)
├── Permissions.swift             AXIsProcessTrusted() checks + System Settings deep link
├── SelectionCapture.swift        Pasteboard snapshot/capture/replace via synthetic ⌘C/⌘A/⌘V,
│                                 ⌘Z undo helper, AX caret-rect lookup; keystrokes are
│                                 posted to the target app's pid (CGEvent.postToPid)
├── EditCoordinator.swift         Orchestrates a cyclical edit session: capture → panel →
│                                 provider → apply inline → iteration history/navigation
├── DebugCLI.swift                --provider-check / --complete headless entry points
├── Actions.swift                 EditAction enum + PromptBuilder (prompt templates)
├── Panel/
│   ├── PanelModel.swift          @Observable state shared between coordinator and view
│   ├── EditPanel.swift           NSPanel host (floating, non-activating; placed at the
│   │                             caret, at the mouse, or centered)
│   ├── PanelKeyCommand.swift     ⌘-shortcut mapping for the panel (no menu bar, so the
│   │                             panel resolves Edit-menu-style key equivalents itself)
│   └── EditPanelView.swift       SwiftUI content (describe field + action rows + status strip)
├── Providers/
│   ├── LLMProvider.swift         LLMProvider/WarmableLLMProvider protocols and ProviderStatus
│   ├── CopilotCLIProvider.swift  GitHub Copilot CLI backend (binary discovery, argv, fallback Process)
│   ├── CopilotACPConfig.swift    ACP sidecar configuration value
│   ├── CopilotACPSidecar.swift   Keeps one Copilot ACP process/session warm
│   ├── CopilotACPClient.swift    Minimal JSON-RPC client for `copilot --acp --stdio`
│   └── CopilotModelCatalog.swift Reads the CLI's cached model list from ~/.copilot/data.db
│                                 (SQLite, read-only) for the settings pickers
└── Settings/
    ├── AppSettings.swift         @Observable, UserDefaults-backed settings + launch-at-login
    └── SettingsView.swift        SwiftUI settings window content

Tests/ManciaTests/ManciaTests.swift   Prompt templates, argv/ACP construction and parsing
                                      (incl. --reasoning-effort), post-processing,
                                      binary discovery order, model-catalog decoding/fallback
                                      (all pure, no process spawning)

Support/Info.plist                   LSUIElement=true, bundle id io.github.peteriz.mancia
scripts/make_app.sh                  swift build -c release → build/Mancia.app, stable codesign when available
```

There is no `Resources/` asset catalog — the menu bar icon is the SF Symbol
`hand.point.up.left.fill`, set directly on the status item's `NSStatusBarButton`.

## Core flow

`AppDelegate.applicationDidFinishLaunching` builds one `CopilotCLIProvider`,
one `EditCoordinator`, one `StatusBarController`, and one `HotkeyManager`, all
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
   and `EditPanel.show(placement:)` positions an `NSPanel`
   (`.nonactivatingPanel` + `.floating`, so the target app keeps focus):
   - next to the caret/selection when there is one, via the Accessibility API
     (`SelectionCapture.selectionScreenRect()`: focused UI element →
     `kAXSelectedTextRange` → `kAXBoundsForRange`, converted from AX top-left
     to AppKit coordinates), falling back to the mouse location;
   - centered on the main screen for entire-document scope;
   - always clamped to the screen's visible frame.
   The panel is a cyclical **edit session**: the describe field and the
   horizontal preset buttons (Proofread / Rewrite / Summarize) are always
   visible, dimmed and disabled while a request runs; a status strip cycles
   `PanelModel.phase` through `.idle → .running → .confirm → .applied/.error`
   and back until the user closes it. The panel **stays visible throughout**: all
   synthetic keystrokes are posted directly to the target app's process
   (`CGEvent.postToPid`), so they cannot be swallowed by the panel and no
   hide/reveal dance is needed. After each keystroke burst (which activates
   the target app) the coordinator calls `panel.focus()` to retake key
   status so Esc and typing reach the panel again.
4. **Perform** — the user picks a built-in `EditAction` or types a free-form
   instruction (`PanelModel.submitInstruction()` → `.custom(text)`).
   `EditCoordinator.perform(_:)` resolves this cycle's input and apply
   strategy (`resolveInput()`):
   - `.document` scope: when the session originally found no selection, first
     probes with a fresh `⌘C`; a new non-empty live selection switches the
     session to `.selection` scope, unless it matches the currently shown
     whole-document version (which can be the app's own previous `⌘A`
     selection). Otherwise it re-captures via `⌘A`+`⌘C` every cycle
     (`SelectionCapture.captureEntireDocument(from:)`); captured text that
     differs from the currently shown version (a manual edit) becomes the new
     session baseline (`versions = [captured]`). Applies with `⌘A`+`⌘V`.
   - `.selection` scope, first cycle: uses the already-captured text and
     pastes over the still-live selection.
   - `.selection` scope, later cycles: probes with a fresh `⌘C`
     (`captureFreshSelection`) — a new user selection becomes the new session
     baseline; otherwise the input is `versions[currentIndex]` (what the
     document shows), applied via **undo-then-paste** (`⌘Z` restores and
     re-selects the previously replaced text in NSTextView-based apps, then
     `⌘V` pastes over it), keeping exactly one paste outstanding.
   It then builds the prompt with `PromptBuilder.build(action:text:)` and
   calls `provider.complete(prompt)` inside a cancellable `Task`. While it
   runs, only the strip's **Cancel** is enabled (spinner + action name).
   Providers that conform to `WarmableLLMProvider` are warmed when the panel
   opens and after it closes; `CopilotCLIProvider` uses that hook to keep one
   empty, single-use ACP session ready for the next edit.
5. **Confirm (whole-document only)** — before a `.document`-scope result
   overwrites the document, the panel pauses in `PanelModel.phase == .confirm`
   (`ApplyConfirmation.isRequired`, gated by
   `AppSettings.confirmWholeDocumentReplace`, default on). The hero button
   becomes **Replace document** (⏎ / `EditCoordinator.confirmApply()`), the
   strip shows the size change (`ApplyConfirmation.summary`), and **Cancel**
   discards the pending result. Selection edits skip this — they are
   low blast-radius and undoable — and apply straight away. This keeps an
   injection-influenced or runaway result from silently replacing everything.
6. **Apply & iterate** — when the result arrives (immediately for selections,
   on confirm for documents),
   `SelectionCapture.apply(text:to:entireDocument:)` pastes it (pasteboard →
   activate target → `⌘V`, restoring the user's pasteboard ~1 s later) with
   the panel still on screen. The coordinator records the iteration
   (`versions`: index 0 is the session original, one entry per applied
   result; running a new action from an earlier version truncates the
   forward history) and the applied strip shows `←` / `→` navigation with a
   "2/3"-style counter plus **Done**.
   - Navigation (`EditCoordinator.navigate(to:)`) rewrites the document with
     `versions[index]`: undo-then-paste for selections (including index 0),
     `⌘A`+`⌘V` for document scope (robust against manual edits in between).
   - **Cancel** (running strip) stops the in-flight `Task` but keeps the
     session open; **Retry** (error strip) re-runs `perform(lastAction)`;
   - **Done**/Esc closes the session, keeping whichever version is showing.

Esc anywhere in the panel routes through `KeyablePanel.cancelOperation` →
`model.onCancel` and closes the session in every phase.

## The `LLMProvider` protocol

```swift
// Sources/Mancia/Providers/LLMProvider.swift
protocol LLMProvider: Sendable {
    var displayName: String { get }
    func complete(_ prompt: String) async throws -> String
    func checkAvailability() async -> ProviderStatus   // .ready / .notFound / .error(String)
}
```

Today the app constructs one `CopilotCLIProvider` directly and passes it to
the places that need completion or availability checks.

`CopilotCLIProvider` uses two execution paths:

- **Primary latency path:** a persistent `copilot --acp --stdio` process, driven
  by `CopilotACPClient` over JSON-RPC. `CopilotACPSidecar` warms one empty
  session while the panel is open; the session is consumed by a single prompt
  and then discarded so selected text cannot carry into later edits.
- **Fallback reliability path:** the original one-shot `copilot -p <prompt>` CLI
  invocation. ACP launch, protocol, empty-output, and timeout failures fall back
  here; user cancellation stays cancellation.

Both paths run in private empty temp directories and use the same ambient-context
disable flags: `--available-tools=`, `--disable-builtin-mcps`, `--no-remote`,
and `--no-custom-instructions`.

To add a new provider:

1. Create `Sources/Mancia/Providers/<Name>Provider.swift` conforming to
   `LLMProvider`. Model it on `CopilotCLIProvider`: keep argv/parsing logic in
   `static` functions so it's unit-testable without spawning a process (see
   `CopilotCLIProvider.arguments`, `.resolveExecutable`, `.postProcess`).
2. Surface configuration in `AppSettings` (`Sources/Mancia/Settings/AppSettings.swift`)
   if the provider needs its own path/model/API-key fields — follow the
   `copilotPath`/`copilotModel`/`reasoningEffort` pattern (`UserDefaults`-backed,
   `didSet` persists). The Copilot model picker is populated by
   `CopilotModelCatalog` from the CLI's SQLite cache (`~/.copilot/data.db`,
   `app_state` key `copilot-available-models`), falling back to "auto" plus
   the stored model string when unreadable; the reasoning-effort picker
   narrows to the selected model's `supportedReasoningEfforts` and is passed
   to the CLI as `--reasoning-effort`.
3. Add a real provider-selection path in `AppSettings` and `SettingsView`
   before wiring multiple providers into `AppDelegate`.
4. Add unit tests alongside the existing ones in
   `Tests/ManciaTests/ManciaTests.swift` for prompt/argv construction and
   output post-processing.
5. If the provider can hide startup latency, conform to `WarmableLLMProvider`;
   warming must be an optimization only, with cancellation and fallback behavior
   matching the synchronous `complete(_:)` path.

`EditCoordinator`, `DebugCLI`, and `StatusBarController` should continue to use
`provider.complete(_:)` / `provider.checkAvailability()` rather than knowing
provider-specific details.

## Prompt gate & injection hardening

The panel's free-form instruction field plus the captured **selected text** form
an open prompt gate. The selected text is untrusted third-party content (an
email, web page, or chat message the user highlighted) and can carry embedded
"instructions", so the defenses target the *data path*, not the user's own
instruction:

- **Sandboxed provider (the real boundary).** Every completion runs through
  either `copilot --acp --stdio` or the one-shot `copilot -p` fallback in a
  private empty temp `cwd`. Both paths pass
  `--available-tools= --disable-builtin-mcps --no-remote --no-custom-instructions`;
  the prompt is sent as ACP JSON-RPC text or as one single `-p` argv element
  (never through a shell). The model therefore has no tools, no repo context, no
  remote-session context, and no shell — the blast radius is "text in, text out".
  `argvAlwaysSandboxed` and the ACP argv/parsing tests lock this invariant so a
  future edit can't silently re-enable ambient context.
- **Nonce-fenced input (`PromptDelimiter`, `Actions.swift`).** Each request wraps
  the instruction and the input text in `[[LABEL:<nonce>]] … [[/LABEL:<nonce>]]`
  markers keyed by an unguessable per-call nonce (`PromptDelimiter.makeNonce`
  also re-rolls if the token happens to appear in the content). Because the
  nonce is unpredictable, text authored ahead of time can't forge a closing
  marker to "escape" its block. An adjacent `treatInputAsDataClause` tells the
  model never to obey instructions found inside the input.
- **Input validation (`PromptGuard.swift`).** `PromptGuard.validate(action:text:)`
  bounds the instruction (`maxInstructionCharacters`) and input text
  (`maxInputCharacters`) and rejects empties, surfacing typed
  `PromptGuardError`s. Both `EditCoordinator.perform` and `DebugCLI.complete`
  validate before building the prompt; failures surface through the panel error
  state / stderr rather than sending a runaway request to the provider.
- **Human-in-the-loop for whole-document overwrites (`ApplyConfirmation`).**
  A `.document`-scope result never auto-pastes: the coordinator pauses in the
  `.confirm` phase and the user must press **Replace document** (the size delta
  is shown as a signal). This bounds the blast radius of an injection-influenced
  or runaway result — the dangerous ⌘A+⌘V path — while leaving low-risk,
  undoable selection edits immediate. Default on
  (`AppSettings.confirmWholeDocumentReplace`), user-toggleable. The confirm/
  keystroke wiring lives in `EditCoordinator`/`EditPanelView` and is verified by
  manual testing; the pure policy (`ApplyConfirmation`) is unit-tested.

Deliberately **not** done: a "jailbreak/abuse classifier" on the instruction
field. Mancia is a single-user local utility — the operator already owns the
authenticated `copilot` binary, so policing their own instruction crosses no
trust boundary and would be trivially bypassable theatre. Prompt wording is UX,
not a security boundary; the sandbox is.

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
`io.github.peteriz.mancia`.

## Build system

- **Package.swift** — swift-tools 6.0, `.macOS(.v14)`, one executable target
  `Mancia` (depends on `sindresorhus/KeyboardShortcuts`), one test target
  `ManciaTests`.
- **Makefile** — `build` (`swift build`), `test` (`swift test`), `app`
  (`scripts/make_app.sh`), `release` (requires explicit `CODESIGN_ID`, then
  `REQUIRE_SIGNING=1 scripts/make_app.sh`),
  `run` (`app` + `open build/Mancia.app`), `clean`
  (`swift package clean` + `rm -rf build`).
- **scripts/make_app.sh** — `swift build -c release`, assembles
  `build/Mancia.app/Contents/{MacOS,Resources}`, copies the binary and
  `Support/Info.plist`, writes a `PkgInfo`, then signs the bundle. Signing
  order is: explicit `CODESIGN_ID`, local `Mancia Dev Signing` certificate, any
  other local `… Dev Signing` identity (e.g. a legacy cert from a previous app
  name), then ad-hoc fallback unless `REQUIRE_SIGNING=1`. Developer ID identities get
  `--options runtime` by default for notarization readiness. Accessibility
  approval survives updates only when `CFBundleIdentifier`
  (`io.github.peteriz.mancia`) and the signing identity stay stable.

## Debug/E2E hooks

`main.swift` checks `DebugCLI.handle(CommandLine.arguments)` before touching
`NSApplication` at all, so these run headless (no UI, no Accessibility
prompt):

- `Mancia --provider-check` — builds the Copilot provider, calls
  `provider.checkAvailability()`, prints `"<displayName>: ready"` (exit 0),
  `"...: not found"` (exit 1), or `"...: error — <message>"` (exit 1).
- `Mancia --complete <action> <<< "text"` — reads stdin as the input text,
  parses `<action>` via `EditAction.parse` (`rewrite | summarize |
  fix-grammar | custom:<instruction>`; unknown values exit 2), builds the
  prompt with `PromptBuilder.build`, calls `provider.complete(prompt)`,
  prints the result (exit 0) or an error to stderr (exit 1). (`fix-grammar`
  is the CLI id for the action labeled **Proofread** in the panel.)

`PromptBuilder` keeps every Copilot prompt template in `Actions.swift`.
Proofread, Rewrite, and Summarize each use a named `PromptTemplate`; Custom
uses the same structure with the user's instruction in its own delimited
section. Every rendered prompt has `Task`, `Requirements`, and delimited
`Input text` sections plus the shared output-only clause, so templates are easy
to review and adjust.

Both run the async body on the main actor via a small `Task { @MainActor in
... }` + `dispatchMain()` shim (`DebugCLI.run`), since there's no
`NSApplication` run loop to drive the actor hops. These flags are the
intended way to exercise the real provider pipeline in CI without simulating
UI or keystrokes.
