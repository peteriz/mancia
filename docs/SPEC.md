# Mancia — Implementation Specification

> **Historical design document.** This is the original v0.1 design spec, kept
> for context. The implemented behavior has since evolved; see
> [ARCHITECTURE.md](ARCHITECTURE.md) and the [README](../README.md) for current
> behavior. Notably:
>
> - **The floating panel is gone.** The edit session now runs in the
>   **command ribbon**: a lane that sits against the selected text — just
>   under it, or just over it when the selection is too near the foot of the
>   host — and falls back to one predictable place (flush under the menu bar,
>   or under the frontmost window's title bar when the menu bar is not
>   reserving a strip) when there is no selection to sit against. It takes the
>   standard or Custom-expanded preferred width, clamped to the host and
>   centered, so it never chases the caret sideways. Its default cells are
>   Target, five Action buttons, and Run; Custom moves left and inserts
>   Direction when selected. The bullets that follow describe the panel that
>   preceded it; the behavior they record carried over to the lane, the
>   placement and the ~360 pt command row did not.
> - The panel was a single command row (~360 pt wide): a free-form
>   instruction field whose trailing controls are a **preset dropdown**
>   (`PanelPreset`) and an accent **run** button. Return and the run button take
>   the same path — an empty field means **Improve** (a proofread-and-rewrite
>   blend), a typed one runs that instruction. There is no separate hero button.
> - The dropdown runs a named preset's specialized template; anything typed in
>   the field rides along as *additional guidance* for that preset rather than
>   replacing it (`PromptBuilder.build(action:text:note:)`). Today the list holds
>   Improve alone. The Rewrite / Summarize / Proofread templates still exist and
>   remain reachable through the debug CLI (`--complete`).
> - There is no Translate or Reply action, and no "Entire document" preview: the
>   scope caption still lets you switch between the selection and the whole
>   document, but there is no separate scope menu screen.
> - Edits **apply immediately** (no preview-then-Apply step). After an edit the
>   surface keeps an iteration history; ⌘Z steps backward through the original
>   and each generated version.
> - After applying, the surface either auto-closes after a short beat or stays
>   open, per the **post-apply behavior** setting. The
>   auto-close beat is abandoned by any sign the user is still working — a
>   keypress, or the ribbon losing key because they clicked back into the host
>   app to select the next span.
> - The Copilot provider now prefers a warmed, single-use ACP session
>   (`copilot --acp --stdio`) for lower latency; the original one-shot
>   `copilot -p` invocation remains the fallback path.

A macOS menu bar app providing system-wide, selection-based AI text editing.
Press a global hotkey in **any** app, and a command ribbon appears at the top of
the screen offering AI actions (Rewrite, Summarize, Fix Grammar, Translate, Reply,
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
│   ├── EditCoordinator.swift      # orchestrates capture → ribbon → provider → apply
│   ├── Panel/                     # shared editing state and chrome
│   │   ├── PanelModel.swift       # observable session state
│   │   ├── KeyablePanel.swift     # non-activating NSPanel that can take key status
│   │   ├── PanelKeyCommand.swift  # ⌘-shortcut and focus-move mapping
│   │   ├── PanelPreset.swift      # the specialized presets
│   │   └── Palette.swift          # shared color tokens
│   ├── Ribbon/
│   │   ├── RibbonWindow.swift     # hosts and places the lane
│   │   ├── RibbonPlacement.swift  # pure placement resolver
│   │   ├── HostWindowProbe.swift  # frontmost window frame + full-screen state
│   │   ├── RibbonView.swift       # the lane's content
│   │   ├── RibbonReviewView.swift # whole-document review gate
│   │   ├── RibbonControls.swift   # controls shared across registers
│   │   └── RibbonPalette.swift    # the lane's color tokens
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
3. **The ribbon opens against the selection**, resolved by
   `RibbonPlacement`: centered on the selected span and as wide as it, just
   under the selected text, or just over it when the selection sits too near
   the foot of the display to fit beneath. The window around the text does not
   move it. With no selection rectangle to work from — a bare caret, a host
   that cannot report bounds, or a selection with nowhere beside it — it falls
   back to one predictable place: flush under the menu bar when the menu bar
   reserves a strip, otherwise under the frontmost window's title bar. It is a
   `KeyablePanel` with `.nonactivatingPanel` style and floating level, so the
   target app keeps focus until the user interacts. Esc closes it.
4. Ribbon UI (SwiftUI, a single lane whose width comes from placement and
   whose height comes from content). Target, five compact Action buttons and Run
   form the default **one-row** interface. Selecting Custom moves that button to
   the leading edge of the action strip, inserts Direction beside it, and grows
   the centered ribbon from its standard width toward its expanded width.
   - **Target** — a chip reading "Selection · N" or "Document", opening a menu
     with the unabbreviated wording. If nothing was selected, default to
     Entire document and drop the menu.
   - **Actions** — Improve, Sharpen, Plan first, Tighten, and Custom are always
     visible as tight buttons. Hovering replaces each title with its ⌘1…⌘5
     shortcut without changing the button's size. Clicking a built-in or
     pressing ⌘1 / ⌘2 / ⌘3 / ⌘4 runs it immediately; ⌘5 selects Custom without
     running it.
   - **Direction** — a hidden-by-default free-form field
     ("Optional instruction…", ⏎ submits). Selecting Custom reveals
     and focuses it with a fast horizontal grow. It wraps to four lines and then
     scrolls, growing the lane; it caps at a readable measure rather than
     absorbing the whole row.
   - **Primary action** — the fixed-width accent control; ⏎ takes the same
     path. It names the selected action ("Improving", "Sharpening", "Planning",
     "Tightening", or "Working"). While a request runs, hovering changes the
     label to "Cancel" and clicking it stops that request.
   - While running: a light travels the primary control's border over a steady
     ember — a bright head over the accent fill, trailing a vermilion glow that
     spills onto the lane so the signal carries from across the row — and a dot
     signals progress. Reduce Motion keeps the ember and drops the movement.
   - Applied state: inline replacement is already pasted; ⌘Z walks backward
     through the retained versions without adding an iteration control to the row.
   - Only a failure opens a **second row**, which carries the message and
     Details / Copy / Retry.
5. **Execution** (`EditCoordinator`):
   - Every cycle first checks that the session's target app is still the
     frontmost one. If the user moved to a different app and selected text
     there, the session re-targets to it: a fresh capture supplies the new
     app's pid and pasteboard snapshot, and the version history resets, since
     that history describes edits made in the old app and replaying it would
     post ⌘Z somewhere Mancia never pasted. With nothing selected in the new
     app the session stays where it is. Mancia itself is never a re-target.
   - A selection captured mid-session — in either scope — becomes the target
     the Target chip describes, so the chip always names the span the run will
     actually send rather than the one the session opened on.
   - If scope is Entire document: activate target app, post ⌘A, then capture
     via ⌘C as above (this yields the document text).
   - Build the prompt from `EditAction` template + text, call the provider
     (async, cancellable via `Task`).
6. **Apply**:
   - Write result to pasteboard, `activate` the target app, wait ~150 ms,
     post ⌘V (for Entire document scope: ⌘A then ⌘V).
   - After ~1 s, restore the user's original pasteboard.
   - While the target app still owns focus, read where the paste left the
     caret. If the ribbon landed on the text it just wrote — a longer result
     flowing past the old selection's foot, or a host that scrolled to keep
     the caret visible — it re-decides its anchor against where that text
     actually is and steps off it; a ribbon already clear of the words holds
     still.
   - Keep the ribbon open for iteration navigation or another edit.

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
- Primary path: keeps one `copilot --acp --stdio` process alive and warms one
  empty session while the ribbon is open. Each warmed session is single-use: once
  a prompt is sent, the session id is discarded so selected text cannot carry
  into later requests.
- Fallback path: runs the original one-shot command,
  `copilot -p <prompt> -s --no-color --no-custom-instructions --available-tools=`
  plus `--model <m>` and `--reasoning-effort <level>` when configured. ACP
  launch, protocol, empty-output, and timeout failures fall back here; user
  cancellation does not.
- **Important:** pass `--available-tools=` as a *single argv element* (empty
  value) in both paths — it disables all agent tools. Both paths also pass
  `--disable-builtin-mcps`, `--no-remote`, and `--no-custom-instructions`.
- Working directory: a private empty temp dir in both paths (avoid the CLI
  scanning a repo).
- 90 s prompt timeout via structured concurrency; kill the one-shot process on
  cancel/timeout and reset the ACP sidecar on ACP failures.
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
  `io.github.peteriz.mancia`. `CFBundleShortVersionString`/`CFBundleVersion` are
  the single source of truth for the version — the release workflow rewrites
  them from the git tag, and the About panel reads them back, so no version
  number is written in Swift or restated here. No sandbox (needed for CGEvent +
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
- No force-unwraps in flow code; errors surface in the ribbon, never crash.
- Keep it small: this is a lightweight utility, not a framework.
