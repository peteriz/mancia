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
- For provider-only checks, prefer:
  - `swift run Mancia --provider-check`
  - `echo "text" | swift run Mancia --complete rewrite`
- For the About panel, run it against the bundle so it can read a real version:
  - `build/Mancia.app/Contents/MacOS/Mancia --about-check`

## Coding Guidelines

- Preserve Swift 6 strict-concurrency safety. Do not paper over data races with
  broad unchecked annotations.
- Keep provider and prompt logic testable with pure/static helpers, following
  `CopilotCLIProvider` and `PromptBuilder`.
- Surface user-facing failures through clear errors or ribbon state, not crashes.
- Avoid new dependencies unless the need is strong and discussed.
- Keep files small and aligned with the existing layout: `Ribbon/`, `Panel/`,
  `Providers/`, `Settings/`, and one primary type per file. `Ribbon/` holds the
  editing surface; `Panel/` holds the state and chrome it shares.
- Be careful with pasteboard, Accessibility, and synthetic keystroke changes:
  they are hard to unit-test, so document manual testing when touched.

## Product Constraints

- The app edits text inline in any frontmost app using pasteboard snapshots and
  synthetic `cmd-C`, `cmd-A`, and `cmd-V`.
- The command ribbon should stay lightweight, fast, and menu-bar-app
  appropriate. It sits against the text being edited — just under the selection,
  just over it when the selection is near the foot of its window, or in the
  margin beside a block too tall for either end. With no selection, or no room
  anywhere beside one, it falls back to a predictable resting place under the
  menu bar or the frontmost window's title bar. It never chases the caret.
- GitHub Copilot CLI is the only provider today; the provider layer is the
  extension point for future backends.
- Development builds are ad-hoc signed, so Accessibility permission may need to
  be re-granted after `make app` or `make run`.
