# AI-Edit — Implementation Specification

A macOS menu bar app providing system-wide, selection-based AI text editing.
Press a global hotkey in **any** app, and a small floating panel appears near the
cursor offering AI actions (Rewrite, Summarize, Fix Grammar, Translate, Reply,
or a free-form instruction). The result replaces the selection inline, or the
whole document when "Entire document" scope is chosen.

## Environment / constraints

- macOS 26.x (Tahoe+), Apple Silicon. Xcode 26.6 / Swift 6.3 available.
- Build with **Swift Package Manager** (no .xcodeproj). An executable target
  plus a `Makefile` that assembles a proper `.app` bundle.
- First LLM provider: **GitHub Copilot CLI** (`copilot` binary, verified
  installed at `/opt/homebrew/bin/copilot`, v1.0.69, authenticated).
- Swift 6 strict concurrency: annotate UI types `@MainActor`; avoid data races.

## Repository layout

```
AI-Edit/
├── Package.swift
├── Makefile
├── Sources/AIEdit/
│   ├── main.swift                 # NSApplication bootstrap (LSUIElement)
│   ├── AppDelegate.swift          # wiring: status item, hotkey, coordinator
│   ├── StatusBarController.swift  # NSStatusItem + menu
│   ├── HotkeyManager.swift        # global hotkey (KeyboardShortcuts pkg)
│   ├── SelectionCapture.swift     # pasteboard-based capture & replace
│   ├── EditCoordinator.swift      # orchestrates capture → panel → provider → apply
│   ├── Panel/
│   │   ├── EditPanel.swift        # floating NSPanel host
│   │   └── EditPanelView.swift    # SwiftUI content
│   ├── Providers/
│   │   ├── LLMProvider.swift      # protocol + registry
│   │   └── CopilotCLIProvider.swift
│   ├── Actions.swift              # EditAction enum + prompt templates
│   ├── Settings/
│   │   ├── AppSettings.swift      # UserDefaults-backed observable settings
│   │   └── SettingsView.swift     # SwiftUI settings window
│   └── Resources/                 # menu bar icon (SF Symbol ok — no asset needed)
├── Tests/AIEditTests/             # unit tests (prompt templates, provider args, trimming)
├── Support/Info.plist             # LSUIElement=true, bundle id io.github.peteriz.ai-edit
├── docs/SPEC.md                   # this file
└── scripts/make_app.sh            # SPM binary → AI-Edit.app, ad-hoc codesign
```

## Dependencies (SPM)

- `sindresorhus/KeyboardShortcuts` (MIT) — configurable global hotkey with a
  recorder control for the settings UI. Default shortcut: **⌃⌥⌘E**.
  No other third-party dependencies.

## Core flow

1. **Hotkey fires** (works system-wide; KeyboardShortcuts handles registration).
2. `SelectionCapture.captureSelection()`:
   - Remember frontmost app (`NSWorkspace.shared.frontmostApplication`).
   - Snapshot pasteboard contents (all string-type items) and `changeCount`.
   - Post ⌘C via `CGEvent` (requires Accessibility permission).
   - Poll `NSPasteboard.general.changeCount` every 30 ms, up to 600 ms.
   - If changed → captured selection string. If not → no selection.
   - Restore the snapshot to the pasteboard afterward.
3. **Panel opens** near the mouse location (clamped to screen). It is an
   `NSPanel` with `.nonactivatingPanel` style, floating level,
   `becomesKeyOnlyIfNeeded`, so the target app keeps focus until the user
   interacts. Esc closes it.
4. Panel UI (SwiftUI, compact, ~380 pt wide):
   - Scope indicator: "Selection (N chars)" or "Entire document" — a segmented
     control. If nothing was selected, default to Entire document and disable
     Selection.
   - Action buttons: Rewrite, Summarize, Fix Grammar, Translate, Reply.
   - Free-form instruction `TextField` ("Or tell the AI what to do…", ⏎ submits).
   - While running: spinner + "Asking Copilot…" + Cancel.
   - Result state: scrollable preview of the response, buttons
     **Apply** (⏎), **Copy**, **Retry**, **Cancel** (Esc).
5. **Execution** (`EditCoordinator`):
   - If scope is Entire document: activate target app, post ⌘A, then capture
     via ⌘C as above (this yields the document text).
   - Build the prompt from `EditAction` template + text, call the provider
     (async, cancellable via `Task`).
6. **Apply**:
   - Write result to pasteboard, `activate` the target app, wait ~150 ms,
     post ⌘V (for Entire document scope: ⌘A then ⌘V).
   - After ~1 s, restore the user's original pasteboard.
   - Close panel.

## Actions & prompts (`Actions.swift`)

`enum EditAction: rewrite, summarize, fixGrammar, translate, reply, custom(String)`.
Every template must end with a strict instruction like:
"Output ONLY the resulting text. No preamble, no explanations, no quotes, no
markdown fences." Translate uses `AppSettings.targetLanguage` (default
"English"). Reply means: draft a reply to the given message (same language as
the message). Keep templates in one place, unit-testable.

## Provider layer

```swift
protocol LLMProvider: Sendable {
    var id: String { get }        // "copilot-cli"
    var displayName: String { get }
    func complete(_ prompt: String) async throws -> String
    func checkAvailability() async -> ProviderStatus  // .ready / .notFound / .error(String)
}
```

`ProviderRegistry` holds available providers; only Copilot for now, but the
settings UI shows a provider picker (single entry + "More providers coming
soon" footnote) so the extension point is visible.

`CopilotCLIProvider`:
- Locates the binary: `AppSettings.copilotPath` if set, else search
  `/opt/homebrew/bin/copilot`, `/usr/local/bin/copilot`, `~/.local/bin/copilot`,
  else `/usr/bin/env copilot`.
- Runs (verified working command):
  `copilot -p <prompt> -s --no-color --no-custom-instructions --available-tools=`
  plus `--model <m>` when `AppSettings.copilotModel` is non-empty.
- **Important:** pass `--available-tools=` as a *single argv element* (empty
  value) — it disables all agent tools.
- Working directory: a private empty temp dir (avoid the CLI scanning a repo).
- 90 s timeout via structured concurrency; kill the process on cancel/timeout.
- Trim whitespace/newlines; strip a single wrapping ``` fence pair if present.
- Errors: non-zero exit → throw with stderr/stdout tail included; binary not
  found → clear message telling the user to `npm install -g @github/copilot`
  or set the path in Settings; not authenticated (detect "not logged in" text)
  → tell user to run `copilot` once in a terminal to sign in.

## Menu bar (`StatusBarController`)

`NSStatusItem` with SF Symbol `wand.and.stars` (template image). Menu:
- "Edit Selection…  ⌃⌥⌘E" (triggers same flow as hotkey, hotkey shown reflects current binding if easy, else static)
- "Provider: GitHub Copilot ✓/⚠︎" (disabled info row reflecting availability check)
- Separator
- "Accessibility permission…" — shown only when not granted; opens System Settings pane
- "Settings…" (⌘,), "About AI-Edit", Separator, "Quit AI-Edit" (⌘Q)

## Settings window

SwiftUI `Settings`-style window (open via menu; make sure it activates the app
so it comes to front). Sections:
- **Shortcut**: `KeyboardShortcuts.Recorder` for the global hotkey.
- **Provider**: picker (GitHub Copilot CLI), model text field (placeholder
  "auto"), copilot binary path field with "Detect" button + status dot
  (green ready / red with error tooltip).
- **Translation**: target language text field (default "English").
- **General**: Launch at login toggle (`SMAppService.mainApp`).

## Permissions

- CGEvent posting requires **Accessibility**. On first trigger, if
  `AXIsProcessTrusted()` is false, call `AXIsProcessTrustedWithOptions` with
  prompt=true and show an explanatory alert; menu item deep-links to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- Info.plist: `LSUIElement = true`, `NSHumanReadableCopyright`, bundle id
  `io.github.peteriz.ai-edit`, version 0.1.0. No sandbox (needed for CGEvent +
  spawning copilot).

## Build

- `Package.swift`: swift-tools 6.0+, platform `.macOS(.v14)` or higher,
  executable `AIEdit`, test target.
- `scripts/make_app.sh`: `swift build -c release`, assemble
  `build/AI-Edit.app/Contents/{MacOS,Resources}`, copy binary + Info.plist,
  write PkgInfo, `codesign --force --deep -s - build/AI-Edit.app`.
- `Makefile` targets: `build` (debug swift build), `test` (swift test),
  `app` (release bundle), `run` (app + `open`), `clean`.

## Debug/E2E hooks (important for automated verification)

The binary accepts CLI flags when run directly (before NSApplication setup):
- `AIEdit --provider-check` → prints provider status, exits.
- `AIEdit --complete <action> <<< "text"` → reads stdin, runs the prompt
  through the real provider, prints result, exits. (action: rewrite|summarize|
  fix-grammar|translate|reply, or `custom:<instruction>`)
These let CI/tests exercise the pipeline without UI.

Additionally, the app registers a URL scheme is NOT required — skip it.

## Unit tests

- Prompt template building for every action (contains the input text and the
  "output only" clause; translate contains the target language).
- Copilot argv construction (including `--available-tools=` and `--model`).
- Output post-processing: trims whitespace, strips code fences, leaves inner
  content intact.
- Provider binary discovery order (injectable file-existence check).

## Quality bar

- `swift build` and `swift test` pass with zero warnings if feasible.
- No force-unwraps in flow code; errors surface in the panel, never crash.
- Keep it small: this is a lightweight utility, not a framework.
