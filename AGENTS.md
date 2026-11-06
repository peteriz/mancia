# Mancia Agent Instructions

Mancia is a small SwiftPM macOS menu bar utility. Keep changes focused,
pragmatic, and proportionate to the app's size.

## Project Shape

- No Xcode project. Use `Package.swift`, `Makefile`, and `scripts/make_app.sh`.
- Main app code lives in `Sources/Mancia`.
- Tests live in `Tests/ManciaTests`.
- Architecture notes are in `docs/ARCHITECTURE.md`; product/spec notes are in
  `docs/SPEC.md`.
- The app is `@MainActor`-heavy AppKit/SwiftUI. UI, hotkey, pasteboard, and
  Accessibility work should stay on the main actor unless there is a clear
  reason not to.

## Build And Test

- `make build` for a debug compile.
- `make test` for unit tests.
- `make app` to assemble `build/Mancia.app`.
- `make run` for the manual app loop.
- Call SwiftPM through `./scripts/swift.sh`, not bare `swift`. Agent
  environments often force `safe.bareRepository=explicit`, which breaks
  dependency resolution; the wrapper overrides it and is a no-op otherwise.
- Tests use swift-testing (`@Test`, `#expect`), not XCTest. Run a subset with
  `./scripts/swift.sh test --filter <TypeOrFunctionName>` (for example
  `EditSafetyTests`); `@Suite`/`@Test` display names do not match.
- For provider-only checks, prefer:
  - `./scripts/swift.sh run Mancia --provider-check`
  - `./scripts/swift.sh run Mancia --list-models`
  - `echo "text" | ./scripts/swift.sh run Mancia --complete rewrite`
- After changing a prompt template, `node scripts/evaluate_action_quality.mjs
  [case-name...]` runs the fixtures in `Tests/Fixtures/action-quality.json`
  against the real Copilot CLI. It is opt-in and spends model calls.
- For the About panel, run it against the bundle so it can read a real version:
  - `build/Mancia.app/Contents/MacOS/Mancia --about-check`
- After touching the ribbon's controls, check they still answer the mouse:
  - `./scripts/swift.sh run Mancia --ribbon-click-check`
- After changing how the ribbon looks, run `make shot` and copy
  `docs/assets/mancia-ribbon.png` to `site/assets/mancia-ribbon.png`.

## Coding Guidelines

- Preserve Swift 6 strict-concurrency safety. Do not paper over data races with
  broad unchecked annotations.
- Keep provider, prompt, and decision logic testable with pure/static helpers,
  following `CopilotCLIProvider`, `PromptBuilder`, `EditSession`, and
  `RibbonPlacement`.
- Surface user-facing failures through clear errors or ribbon state, not crashes.
- Avoid new dependencies unless the need is strong and discussed.
- Keep files small and aligned with the existing layout: `Ribbon/`, `Panel/`,
  `Providers/`, `Settings/`, and one primary type per file. `Ribbon/` holds the
  editing surface; `Panel/` holds the state and chrome it shares.
- Be careful with pasteboard, Accessibility, and synthetic keystroke changes:
  they are hard to unit-test, so document manual testing when touched. For
  Slack/Electron hosts, follow "Manual Slack edit checks" in
  `docs/CONTRIBUTING.md`.

## Docs, PRs, And Releases

- Add user-visible changes under `## [Unreleased]` in `CHANGELOG.md`.
- When adding, moving, or removing a source file or debug flag, update the
  component map and Debug/E2E hooks in `docs/ARCHITECTURE.md`.
- PR bodies follow `.github/PULL_REQUEST_TEMPLATE.md`.
- Releases: follow "Releasing" in `docs/CONTRIBUTING.md`. Bump both version
  keys in `Support/Info.plist` and date the changelog section in one PR (a test
  keeps them in step), then push a tag. Never create or publish a GitHub
  release by hand; the release workflow owns it because releases are
  immutable.

## Product Constraints

- The app edits text inline in any frontmost app using pasteboard snapshots and
  synthetic `cmd-C`, `cmd-A`, and `cmd-V`.
- The command ribbon should stay lightweight, fast, and menu-bar-app
  appropriate. It sits against the text being edited, and the selected span —
  not the window around it — is what drives where it goes: centered on the
  span and as wide as it, just under the selection, just over it when the
  selection is near the foot of the display, or in the margin beside a block
  too tall for either end. With no selection (the whole document is the
  target), or no room anywhere beside one, it falls back to a predictable
  resting place under the menu bar or the frontmost window's title bar. It
  never chases the caret.
- GitHub Copilot CLI is the only provider today; the provider layer is the
  extension point for future backends.
- Development builds are ad-hoc signed, so Accessibility permission may need to
  be re-granted after `make app` or `make run`.
