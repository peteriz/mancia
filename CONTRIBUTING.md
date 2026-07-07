# Contributing to Mancia

Thanks for taking a look. Mancia is intentionally small — please keep
changes proportionate to that (see the "Quality bar" note in
`docs/SPEC.md`: this is a lightweight utility, not a framework).

## Dev setup

- macOS 14+, a recent Xcode/Swift toolchain (Swift 6).
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) installed and
  authenticated if you want to exercise the real provider end-to-end:
  ```sh
  npm install -g @github/copilot
  copilot   # once, to sign in
  ```
- No Xcode project to open — this is a pure Swift Package Manager project.

## Build & test

```sh
make build   # swift build            — debug compile
make test    # swift test             — unit tests
make app     # scripts/make_app.sh    — release build + build/Mancia.app
make release # scripts/make_app.sh    — same, but requires explicit CODESIGN_ID
make run     # make app && open build/Mancia.app — fastest way to try changes
make clean   # swift package clean && rm -rf build
```

`make run` is the tightest loop for manual testing since it produces a real
signed `.app` you can trigger the hotkey against. To avoid re-granting
Accessibility after every rebuild, create a persistent "Mancia Dev Signing"
code-signing certificate in Keychain Access or pass one explicitly:

```sh
CODESIGN_ID="Mancia Dev Signing" make run
```

The app falls back to ad-hoc signing when no identity is available; those
builds may need Accessibility re-approval after each rebuild.

For GitHub releases, set `CODESIGN_ID` explicitly and use the same Developer
ID Application certificate every time:

```sh
CODESIGN_ID="Developer ID Application: Your Name (TEAMID)" make release
```

Do not change `CFBundleIdentifier` (`io.github.peteriz.mancia`) between
releases unless you are intentionally forcing users to approve permissions
again.

For pipeline changes that don't need the UI, use the debug hooks instead of
clicking through the panel:

```sh
swift run Mancia --provider-check
echo "some text" | swift run Mancia --complete rewrite
```

## Code style

- **Swift 6 strict concurrency.** The package builds under the Swift 6
  language mode (`swift-tools-version:6.0`); don't introduce data races or
  suppress concurrency checking to make something compile.
- **`@MainActor` on UI-facing types.** `AppDelegate`, `StatusBarController`,
  `HotkeyManager`, `EditCoordinator`, `EditPanel`, `PanelModel`,
  `AppSettings`, `Permissions`, and `SelectionCapture` are all `@MainActor`
  — keep new UI/AppKit-touching code the same way rather than sprinkling
  `DispatchQueue.main.async`. Only isolate types off the main actor when they
  genuinely need to (e.g. `CopilotCLIProvider`'s `ProcessRunner`, marked
  `@unchecked Sendable` because it privately owns a single blocking
  `Process`).
- **Keep provider/prompt logic in testable `static` functions.** See
  `CopilotCLIProvider.arguments(executable:prompt:model:)`,
  `.resolveExecutable(override:fileExists:)`, and `.postProcess(_:)` — pure,
  synchronous, injectable, and covered by
  `Tests/ManciaTests/ManciaTests.swift` without spawning a real process.
  New providers should follow the same shape.
- **No force-unwraps in flow code.** Errors should surface in the panel
  (`PanelModel.errorText` / `.error` phase) or as a `ProviderError` case with
  an actionable `errorDescription`, never a crash.
- Favor small, single-purpose files matching the existing layout (one type
  per file, grouped into `Panel/`, `Providers/`, `Settings/`).

## Adding a new edit action

Everything about an action lives in `Sources/Mancia/Actions.swift`:

1. Add a case to `EditAction` (or reuse `.custom(String)` if it's really a
   user-supplied instruction, not a fixed action).
2. Give it a `title` and SF Symbol `symbol`.
3. Add its identifier to `EditAction.parse(_:)` so it works from
   `--complete <action>` too.
4. Add its prompt instruction to `PromptBuilder.build(action:text:targetLanguage:)`.
   Every instruction must still end with `PromptBuilder.outputOnlyClause`
   (enforced implicitly by the shared template — don't build a separate
   return path that skips it).
5. Add the button to the `actions` array in
   `Sources/Mancia/Panel/EditPanelView.swift`.
6. Add a test in `Tests/ManciaTests/ManciaTests.swift` asserting the prompt
   contains the input text and the output-only clause (extend the existing
   `actions` array in `promptContainsTextAndClause`).

## Adding a new provider

See "The `LLMProvider` protocol and adding a provider" in
`docs/ARCHITECTURE.md` for the concrete steps and file references — it walks
through conforming to `LLMProvider`, wiring settings, registering in
`ProviderRegistry.makeDefault(settings:)`, and updating `SettingsView`.

## Pull requests

- Keep PRs focused — one behavior change or fix at a time.
- Run `make test` before opening the PR; if you touched provider/prompt
  logic, add or update unit tests rather than relying on manual testing.
- Describe what you tested manually if the change affects the hotkey, panel,
  or pasteboard flow (this is genuinely hard to unit-test end-to-end).
- Don't add third-party dependencies without discussion first — the project
  deliberately has exactly one (`KeyboardShortcuts`).
