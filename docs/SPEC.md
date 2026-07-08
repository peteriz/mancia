# Mancia — Implementation Specification

> **Historical design document.** This is the original v0.1 design spec, kept
> for context. The implemented behavior has since evolved; see
> [ARCHITECTURE.md](ARCHITECTURE.md) and the [README](../README.md) for current
> behavior. Notably:
>
> - The panel's actions are now a single hero **Improve** button (a
>   proofread-and-rewrite blend) plus a free-form instruction field. The
>   separate Proofread / Rewrite / Summarize preset buttons were dropped from
>   the UI; those templates survive only as prompt logic reachable through the
>   debug CLI (`--complete`).
> - There is no Translate or Reply action, and no "Entire document" preview: the
>   scope caption still lets you switch between the selection and the whole
>   document, but there is no separate scope menu screen.
> - Edits **apply immediately** (no preview-then-Apply step). After an edit the
>   panel keeps an iteration history and shows `←` / `→` version navigation so
>   you can move between the original and each generated version.
> - After applying, the panel either flashes "Improved" and auto-closes or stays
>   open with the version strip, per the **post-apply behavior** setting.

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
Mancia/
├── Package.swift
├── Makefile
├── Sources/Mancia/
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
│   │   ├── LLMProvider.swift      # protocol + ProviderStatus
│   │   ├── CopilotCLIProvider.swift
│   │   └── CopilotModelCatalog.swift
│   ├── Actions.swift              # EditAction enum + prompt templates
│   ├── Settings/
│   │   ├── AppSettings.swift      # UserDefaults-backed observable settings
│   │   └── SettingsView.swift     # SwiftUI settings window
├── Tests/ManciaTests/             # unit tests (prompt templates, provider args, trimming)
├── Support/Info.plist             # LSUIElement=true, bundle id io.github.peteriz.mancia
├── docs/SPEC.md                   # this file
└── scripts/make_app.sh            # SPM binary → Mancia.app, stable codesign when available
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
4. Panel UI (SwiftUI, compact, ~310 pt wide):
   - Free-form instruction `TextField` ("Describe your change…", ⏎ submits)
     with a trailing submit button.
   - Equal-width preset buttons: Proofread, Rewrite, Summarize.
   - Scope menu: "Selection · N chars" or "Entire document". If nothing was
     selected, default to Entire document.
   - While running: spinner + action name + Cancel.
   - Applied state: inline replacement is already pasted; show version
     navigation plus Done.
5. **Execution** (`EditCoordinator`):
   - If scope is Entire document: activate target app, post ⌘A, then capture
     via ⌘C as above (this yields the document text).
   - Build the prompt from `EditAction` template + text, call the provider
     (async, cancellable via `Task`).
6. **Apply**:
   - Write result to pasteboard, `activate` the target app, wait ~150 ms,
     post ⌘V (for Entire document scope: ⌘A then ⌘V).
   - After ~1 s, restore the user's original pasteboard.
   - Keep the panel open for iteration navigation or another edit.

## Actions & prompts (`Actions.swift`)

`enum EditAction: rewrite, summarize, fixGrammar, custom(String)`.
`PromptBuilder.build(action:text:)` is the only path that turns an action into
the prompt sent to Copilot. Each preset action has a named `PromptTemplate` in
`Actions.swift`:

- **Proofread** (`fixGrammar`) — correct spelling, grammar, punctuation, and
  typos while changing only what is needed for correctness.
- **Rewrite** — improve clarity, flow, and natural phrasing while preserving
  meaning, facts, tone, language, formatting, and approximate length.
- **Summarize** — keep the main point, key decisions, names, numbers, dates,
  and constraints while removing repetition and unnecessary supporting detail.
- **Custom** — puts the user's free-form instruction in its own delimited
  section, then preserves anything not targeted by that instruction.

All templates render with the same sections (`Task`, `Requirements`, delimited
`Input text`) and include the strict output rule:
"Return only the resulting text. Do not include a preamble, explanation,
quotation marks, or Markdown code fence." Keep templates in one place,
unit-testable.

## Provider layer

```swift
protocol LLMProvider: Sendable {
    var displayName: String { get }
    func complete(_ prompt: String) async throws -> String
    func checkAvailability() async -> ProviderStatus  // .ready / .notFound / .error(String)
}
```

`AppDelegate` builds the single `CopilotCLIProvider` and passes it directly to
the coordinator, status menu, settings view, and debug CLI.

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

`NSStatusItem` with SF Symbol `hand.point.up.left.fill` (template image). Menu:
- "Edit Selection…  ⌃⌥⌘E" (triggers same flow as hotkey, hotkey shown reflects current binding if easy, else static)
- "Provider: GitHub Copilot ✓/⚠︎" (disabled info row reflecting availability check)
- Separator
- "Accessibility permission…" — shown only when not granted; opens System Settings pane
- "Settings…" (⌘,), "About Mancia", Separator, "Quit Mancia" (⌘Q)

## Settings window

SwiftUI `Settings`-style window (open via menu; make sure it activates the app
so it comes to front). Sections:
- **Shortcut**: `KeyboardShortcuts.Recorder` for the global hotkey.
- **GitHub Copilot CLI**: model picker, reasoning-effort picker, Copilot binary
  path field with "Detect" button + status dot (green ready / red with error
  tooltip).
- **General**: Launch at login toggle (`SMAppService.mainApp`).

## Permissions

- CGEvent posting requires **Accessibility**. On first trigger, if
  `AXIsProcessTrusted()` is false, call `AXIsProcessTrustedWithOptions` with
  prompt=true and show an explanatory alert; menu item deep-links to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
- Info.plist: `LSUIElement = true`, `NSHumanReadableCopyright`, bundle id
  `io.github.peteriz.mancia`, version 0.1.0. No sandbox (needed for CGEvent +
  spawning copilot).

## Build

- `Package.swift`: swift-tools 6.0+, platform `.macOS(.v14)` or higher,
  executable `Mancia`, test target.
- `scripts/make_app.sh`: `swift build -c release`, assemble
  `build/Mancia.app/Contents/{MacOS,Resources}`, copy binary + Info.plist,
  write PkgInfo, then sign with `CODESIGN_ID`, local `Mancia Dev Signing`, any
  other local `… Dev Signing` identity, or ad-hoc fallback.
- `Makefile` targets: `build` (debug swift build), `test` (swift test),
  `app` (release bundle), `release` (requires explicit `CODESIGN_ID`), `run`
  (app + `open`), `clean`.

## Debug/E2E hooks (important for automated verification)

The binary accepts CLI flags when run directly (before NSApplication setup):
- `Mancia --provider-check` → prints provider status, exits.
- `Mancia --complete <action> <<< "text"` → reads stdin, runs the prompt
  through the real provider, prints result, exits. (action: rewrite|summarize|
  fix-grammar, or `custom:<instruction>`)
These let CI/tests exercise the pipeline without UI.

Additionally, the app registers a URL scheme is NOT required — skip it.

## Unit tests

- Prompt template building for every action (contains the input text and the
  "output only" clause).
- Copilot argv construction (including `--available-tools=` and `--model`).
- Output post-processing: trims whitespace, strips code fences, leaves inner
  content intact.
- Provider binary discovery order (injectable file-existence check).

## Quality bar

- `swift build` and `swift test` pass with zero warnings if feasible.
- No force-unwraps in flow code; errors surface in the panel, never crash.
- Keep it small: this is a lightweight utility, not a framework.
