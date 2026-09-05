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
├── StatusBarController.swift     NSStatusItem + menu (Edit / Provider status / Settings /
│                                 About / Quit)
├── HotkeyManager.swift           Registers the global hotkey (KeyboardShortcuts pkg)
├── Permissions.swift             AXIsProcessTrusted() checks + System Settings deep link
├── SelectionCapture.swift        Operation-local pasteboard capture, AX target evidence,
│                                 verified range reselection and paste; keystrokes are
│                                 posted to the target app's pid (CGEvent.postToPid)
├── EditCoordinator.swift         Drives a cyclical edit session: capture → ribbon →
│                                 provider → apply inline → iteration history/navigation
├── EditSession.swift             Pure decision core for a session — which text each cycle
│                                 sends, how the result goes back, and the version history
├── DebugCLI.swift                --provider-check / --complete / --about-check /
│                                 --ribbon-click-check headless and UI entry points
├── AboutPanel.swift              The standard About panel's options, icon, and presentation
├── AppVersion.swift              Reads the version from the bundle; no version literal in Swift
├── Actions.swift                 EditAction enum + PromptBuilder (prompt templates)
├── Panel/
│   ├── PanelModel.swift          @Observable state shared between coordinator and view
│   ├── KeyablePanel.swift        NSPanel subclass that can take key status while the
│   │                             target app stays active (.nonactivatingPanel)
│   ├── Palette.swift             Shared color tokens
│   ├── PanelPreset.swift         Improve / Sharpen / Plan first / Tighten
│   └── PanelKeyCommand.swift     ⌘-shortcut and focus-move mapping for the editing surface
│                                 (no menu bar, so it resolves Edit-menu-style key
│                                 equivalents itself)
├── Ribbon/
│   ├── RibbonWindow.swift        Hosts the lane: measures the view at the resolved width,
│   │                             sets the frame, animates entry/exit, tracks screen changes
│   ├── RibbonPlacement.swift     Pure placement resolver — sits against the selection when
│   │                             the host reports one (under it, over it, or in the margin
│   │                             beside a tall block), else under the menu bar or the
│   │                             host's title bar
│   ├── HostWindowProbe.swift     Reads the frontmost window's frame and full-screen state
│   │                             through Accessibility (placement's second input)
│   ├── RibbonView.swift          Target, five actions, Custom editor, progress and recovery
│   ├── RibbonReviewView.swift    The whole-document review gate
│   ├── RibbonControls.swift      Controls shared across the lane's registers
│   └── RibbonPalette.swift       Appearance-adaptive lane and state colors
├── Providers/
│   ├── LLMProvider.swift         LLMProvider/WarmableLLMProvider protocols and ProviderStatus
│   ├── CopilotCLIProvider.swift  GitHub Copilot CLI backend (binary discovery, argv, fallback Process)
│   ├── CopilotACPConfig.swift    ACP sidecar configuration value
│   ├── CopilotACPSidecar.swift   Keeps one Copilot ACP process/session warm
│   ├── CopilotACPClient.swift    Minimal JSON-RPC client for `copilot --acp --stdio`
│   └── CopilotModelCatalog.swift Reads the CLI's cached model list from ~/.copilot/data.db
│                                 (SQLite, read-only) and merges it with the live
│                                 ACP listing for the settings pickers
└── Settings/
    ├── AppSettings.swift         @Observable, UserDefaults-backed settings + launch-at-login
    │                                 + the swoosh color (stored as RRGGBB hex)
    ├── SettingsView.swift        SwiftUI settings window content
    ├── ReadinessRow.swift        One "is this ready?" row (hotkey / Accessibility / provider)
    └── ShortcutRecorderView.swift  Native hotkey recorder (see note below)

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

1. **Trigger and capture.** The hotkey or menu calls `coordinator.start()`.
   Accessibility permission is required. The ribbon opens while capture runs.
   `SelectionCapture` records the host application and available AX
   field/window/range identity, then reads the selection. A proved empty
   selection is distinct from an uncertain or failed copy.
2. **Scope consent.** The target control states Selection or Whole document.
   Whole-document requests pause in `.scopeApproval` before capturing and
   sending document text. This approval is separate from the configurable
   replacement confirmation. Uncertain capture does not imply document scope.
3. **Generation.** `EditSession` binds each request to its scope, baseline,
   target evidence, and revision. Scope or target changes invalidate pending
   approvals and results. `PromptGuard` validates the input before
   `PromptBuilder` builds the prompt. Providers receive only the prompt and
   return text; the coordinator remains responsible for editorial normalization.
4. **Output and review.** `PromptBuilder.normalizeOutput` preserves preset
   selection-edge whitespace and leaves intentional Custom formatting intact.
   Unchanged results do not create paste operations or history entries.
   Whole-document results enter `.confirm` when replacement confirmation is
   enabled. The original and proposed result remain available for comparison.
5. **Verified application.** Before posting Paste, `SelectionCapture` verifies
   that the same editable field still contains the captured baseline. AX range
   reselection replaces the exact span; Mancia never sends Undo to discover
   what is on a host's undo stack. After paste, the expected field value must
   be observed before the coordinator records a successful history entry.
   Missing evidence, changed contents, or unsupported hosts leave a copyable
   result in `.retained` rather than attempting an unsafe replacement.
6. **Iteration and recovery.** A fresh selection supplies new target evidence.
   History navigation uses the verified current field and range, and commits
   its index only after replacement succeeds. Custom's draft survives
   successful edits in the open session. Pending approvals, errors, and
   retained results do not auto-close; the normal applied state retains the
   configured post-edit behavior.

### Clipboard and cancellation boundaries

Each copy/paste operation snapshots the pasteboard immediately before using
it. `PasteboardOwnership` records the temporary contents and change count;
restoration only occurs if those still match. A newer copy made by the user
takes precedence over restoration.

Cancellation is checked before synthetic keystrokes. Paste is the commitment
point: cancelling beforehand prevents replacement, but cancelling afterward
cannot imply that the document was left untouched. Cleanup must finish without
overwriting a newer clipboard value. A generated result and a verified applied
result are distinct outcomes.

Replacement is plain text. AX identity and full-field reads are not available
in every host; this limits in-place editing and history, not the ability to
return generated text for copying. Rich-text reconstruction is not implemented.

### Ribbon placement and keyboard behavior

`RibbonPlacement` remains a pure resolver. It places the ribbon below or above
the selected span, beside a tall block, or at a predictable menu-bar/title-bar
fallback. The established anchor is retained while content grows, except when
the target moves or the ribbon would obscure newly applied text. The window
measures content at the resolved width before setting its height.

The five action names stay visible on hover. Custom discloses a bounded
multiline editor. The target control, progress, approvals, review, and retained
results share the same ribbon rather than separate windows.

`PanelKeyCommand` and `KeyablePanel` route shortcuts. `PanelModel.focusedCell`
is the authority for Tab order and focus rings, including recovery and
approval controls. Return activates the focused control, not an unconditional
document replacement. Command-number shortcuts retain their action order;
Command-T changes scope only when permitted. Escape backs out of the current
run or pending approval; Command-W closes the session.

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
  session while the lane is open; the session is consumed by a single prompt
  and then discarded so selected text cannot carry into later edits.
- **Fallback reliability path:** the original one-shot `copilot -p <prompt>` CLI
  invocation. ACP launch, protocol, and empty-output failures fall back here;
  cancellation and timeout stop the request.

Both paths run in private empty temp directories and use the same ambient-context
disable flags: `--available-tools=`, `--disable-builtin-mcps`, `--no-remote`,
and `--no-custom-instructions`.

Availability probing runs `copilot --version`. Success means **Installed**,
not authenticated or able to complete a network request. Completion errors
provide the sign-in or service failure details when the user runs an action.
The model recommendation uses backend speed/cost metadata, not an
editing-quality score; explicit model choices remain unchanged.

To add a new provider:

1. Create `Sources/Mancia/Providers/<Name>Provider.swift` conforming to
   `LLMProvider`. Model it on `CopilotCLIProvider`: keep argv/parsing logic in
   `static` functions so it's unit-testable without spawning a process (see
   `CopilotCLIProvider.arguments`, `.resolveExecutable`, `.postProcess`).
2. Surface configuration in `AppSettings` (`Sources/Mancia/Settings/AppSettings.swift`)
   if the provider needs its own path/model/API-key fields — follow the
   `copilotPath`/`copilotModel`/`reasoningEffort` pattern (`UserDefaults`-backed,
   `didSet` persists). The Copilot model picker opens on `CopilotModelCatalog`'s
   read of the CLI's SQLite cache (`~/.copilot/data.db`, `app_state` key
   `copilot-available-models`), falling back to "auto" plus the stored model
   string when unreadable, then upgrades to the live list. That cache is only
   rewritten by the interactive Copilot TUI, so on a machine that drives Copilot
   solely through Mancia it goes stale and hides newly released models; the
   authoritative list therefore comes from the `session/new` ACP reply, which
   already carries `models.availableModels` (see `ModelListingProvider` and
   `CopilotModelCatalog.merged`). ACP omits the latency tier, so
   `modelPickerCategory` is carried over from the cache by id, and a model
   present only in the live listing is tiered by its price class. The selected
   model's effective `supportedReasoningEfforts` comes from the live
   `reasoning_effort` session config option; cached values remain the fallback
   for models not selected yet. Mancia refreshes this live metadata at launch
   and after Settings closes, then explicitly applies both `model` and
   `reasoning_effort` with ACP `session/set_config_option` for every new session
   so Copilot's persisted session state cannot override the selection. Check
   what the picker will show with
   `swift run Mancia --list-models`.

   **Keep the catalog free of hardcoded model ids.** Tiering and the first-run
   recommendation (`recommendedFastModel`) are derived from what the backend
   advertises: the latency class, the price class, and the premium-request
   multiplier (`_meta.copilotUsage`, live only). Within each tier, picker rows
   group by the model name's leading provider-family prefix, providers sort
   A-Z, and each provider's models sort newest/highest first by natural name.
   Copilot exposes no provider field, so an unknown prefix simply forms its own
   group rather than requiring an allowlist. A model released tomorrow is
   tiered, ordered, and can become the recommended default with no code change,
   and a retired one disappears on its own. Named-id lists rot silently as
   models come and go, so add signals rather than special cases. Unknown enum
   values (a new latency class, price class, or reasoning-effort level) must
   degrade to a sensible default instead of dropping the model. The
   reasoning-effort picker
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

The lane's disclosed free-form Direction field plus the captured **selected text** form
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
  validate before building the prompt; failures surface through the lane's error
  state / stderr rather than sending a runaway request to the provider.
- **Whole-document consent and replacement review (`ApplyConfirmation`).**
  Document requests always pause before reading and sending the document.
  Separately, replacement review is enabled by default and controlled by
  `AppSettings.confirmWholeDocumentReplace`. Both confirmed and immediate
  replacements still require fresh target/baseline verification; approval is
  not permission to overwrite a field that changed while the model ran.

Deliberately **not** done: a "jailbreak/abuse classifier" on the instruction
field. Mancia is a single-user local utility — the operator already owns the
authenticated `copilot` binary, so policing their own instruction crosses no
trust boundary and would be trivially bypassable theatre. Prompt wording is UX,
not a security boundary; the sandbox is.

### Action-quality evaluation

`Tests/Fixtures/action-quality.json` contains synthetic cases for the five
visible actions. Unit tests cover prompt contracts, fixture structure, raw
output validation, and action-aware boundary normalization without contacting
Copilot. `node scripts/evaluate_action_quality.mjs [case-name...]` is an
explicit, local opt-in evaluation against the configured model. It reports
literal checks and prints criteria for human review; it does not equate
substring preservation with semantic accuracy.

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
- **Native hotkey recorder** — Settings rebinds the global shortcut through
  `Settings/ShortcutRecorderView.swift`, not `KeyboardShortcuts.Recorder`. The
  upstream recorder loads localized strings from the package's `Bundle.module`,
  whose SwiftPM-generated accessor resolves the resource bundle against
  `Bundle.main.bundleURL` — the `.app` root in a hand-assembled bundle. macOS
  forbids loose content beside `Contents/` (codesign rejects it, so we can't put
  it there), and the accessor's only fallback is the build-machine path, so a
  code-signed release fatal-errored the moment Settings opened. The native
  recorder uses KeyboardShortcuts' public `setShortcut`/`getShortcut` API and
  formats the shortcut itself, so `Bundle.module` is never touched. The recorder
  is UI/pasteboard-adjacent (a local `NSEvent` key monitor); its pure helpers
  are unit-tested, and the record/persist path is manually verified.
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
  parses `<action>` via `EditAction.parse` (`improve | sharpen | plan-first |
  tighten | rewrite | summarize | fix-grammar | custom:<instruction>`; unknown
  values exit 2), builds the prompt with `PromptBuilder.build`, calls
  `provider.complete(prompt)`, prints the result (exit 0) or an error to stderr
  (exit 1). (`fix-grammar` is the CLI id for the action labeled **Proofread** in
  the lane, and `plan-first` for **Plan first**.)

`PromptBuilder` keeps every Copilot prompt template in `Actions.swift`. Improve,
Sharpen, Plan first, Tighten, Proofread, Rewrite, and Summarize each use a named
`PromptTemplate`; Custom uses the same structure with the user's instruction in
its own delimited section. Every rendered prompt has `Task`, `Requirements`, and
delimited `Input text` sections plus the shared output-only clause, so templates
are easy to review and adjust.

The dropdown presets past Improve target text written for coding agents, and all
three restructure rather than generate — they are forbidden from inventing
requirements, which both protects the prompt's meaning and keeps output roughly
input-sized (and so keeps the edit fast):

- **Sharpen** — goal first in imperative voice, constraints and success criteria
  as explicit lines, concrete anchors (paths, commands, errors) kept verbatim.
- **Plan first** — reframes an implementation request as an
  investigate-then-plan request, without answering it.
- **Tighten** — shortest faithful version; cuts filler only, and unlike
  Summarize may not drop any requirement.

Both run the async body on the main actor via a small `Task { @MainActor in
... }` + `dispatchMain()` shim (`DebugCLI.run`), since there's no
`NSApplication` run loop to drive the actor hops. These flags are the
intended way to exercise the real provider pipeline in CI without simulating
UI or keystrokes.
