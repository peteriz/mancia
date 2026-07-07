# Contributing to Mancia

Thanks for taking a look. Mancia is intentionally small, so keep changes
focused and proportionate.

## Setup

- macOS 14 or newer.
- A recent Xcode/Swift toolchain with Swift 6 support.
- GitHub Copilot CLI installed and signed in if you want to test the real
  provider:

```sh
npm install -g @github/copilot
copilot
```

## Build And Test

```sh
make build
make test
make app
make run
```

For provider-only checks:

```sh
swift run Mancia --provider-check
echo "some text" | swift run Mancia --complete rewrite
```

`make run` is the fastest manual loop because it builds a real `.app` bundle.
To avoid re-granting Accessibility after every rebuild, use a stable local
signing identity:

```sh
CODESIGN_ID="Mancia Dev Signing" make run
```

## Code Style

- Preserve Swift 6 strict-concurrency safety.
- Keep UI, hotkey, pasteboard, and Accessibility code on the main actor unless
  there is a clear reason not to.
- Keep provider and prompt logic testable with pure/static helpers.
- Surface user-facing failures as clear errors or panel state, not crashes.
- Avoid new dependencies unless the need is strong and discussed first.
- Keep files small and aligned with the existing layout: `Panel/`, `Providers/`,
  `Settings/`, and one primary type per file.

## Pull Requests

- Keep PRs focused.
- Run `make test` before opening a PR.
- Add or update tests for prompt/provider logic.
- Document manual testing for hotkey, panel, pasteboard, or Accessibility
  changes.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the current app structure and
[SPEC.md](SPEC.md) for implementation notes.
