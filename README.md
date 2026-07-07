# AI-Edit

AI-Edit is a small macOS menu bar utility that puts an AI text edit within a
keystroke of anywhere you type. Press a global hotkey in any app, and a
floating panel appears next to your cursor offering quick actions — Rewrite,
Summarize, Fix Grammar, Translate, Reply — or a free-form instruction you type
yourself. The result replaces your current selection, or the whole document,
right where you were typing. No copy-pasting into a chat window, no context
switch.

```
  ⌃⌥⌘E in any app
        │
        ▼
  ┌───────────────┐      ⌘C       ┌──────────────┐
  │ Selection /   │ ─────────────▶│  Copilot CLI │
  │ Entire doc    │◀───────────── │  (non-interactive) │
  └───────────────┘   result       └──────────────┘
        │
        ▼
  ⌘V back into the same field
```

## Features

- **Global hotkey** (default `⌃⌥⌘E`, remappable) works system-wide, in any app.
- **Floating panel** appears near your cursor without stealing focus from the
  app you're editing in.
- **Five built-in actions** — Rewrite, Summarize, Fix Grammar, Translate,
  Reply — plus a free-form instruction field for anything else.
- **Two scopes** — edit just the current selection, or the entire document
  (select-all under the hood).
- **Result preview** before it lands — Apply, Copy, or Retry before committing
  the change.
- **Menu bar only** — no Dock icon, no app windows to manage.
- **Pluggable provider layer** — ships with GitHub Copilot CLI today; the
  `LLMProvider` protocol is designed so more backends can be added later.

## Requirements

- macOS 14 or later.
- [GitHub Copilot CLI](https://github.com/github/copilot-cli) installed and
  authenticated:

  ```sh
  npm install -g @github/copilot
  copilot   # run once, follow the prompts to sign in
  ```

  AI-Edit shells out to this `copilot` binary in non-interactive mode; it
  does not talk to any AI API directly.

## Install / build

AI-Edit is built with Swift Package Manager — there is no Xcode project.

```sh
git clone https://github.com/peteriz/ai-edit.git
cd ai-edit
make app          # swift build -c release, then assembles build/AI-Edit.app
```

Then drag (or copy) `build/AI-Edit.app` into `/Applications`.

Other Makefile targets:

| Target      | What it does                                              |
|-------------|------------------------------------------------------------|
| `make build`| Debug build (`swift build`) — compiles, no app bundle.     |
| `make test` | Runs the unit tests (`swift test`).                         |
| `make app`  | Release build + assembles `build/AI-Edit.app` (ad-hoc signed). |
| `make run`  | `make app`, then `open build/AI-Edit.app` — quick dev loop. |
| `make clean`| `swift package clean` + removes `build/`.                   |

For day-to-day development, `make run` is the fastest way to try changes: it
rebuilds the release bundle and launches it.

## First run: grant Accessibility permission

AI-Edit reads your selection and pastes results back by posting synthetic
`⌘C` / `⌘A` / `⌘V` keystrokes to whatever app is in front — this is how it
works in *any* app without per-app integrations. macOS requires
**Accessibility** access for a process to post synthetic keystrokes.

The first time you trigger the hotkey, AI-Edit will prompt you (or you can
grant it ahead of time):

1. Open **System Settings ▸ Privacy & Security ▸ Accessibility**.
2. Enable the toggle for **AI-Edit**.
3. If AI-Edit doesn't appear in the list yet, trigger the hotkey once — macOS
   adds the entry automatically (initially unchecked), then enable it there,
   or use the menu bar item **"Accessibility permission…"** which deep-links
   straight to this pane.

Note: because this permission is tied to the specific app binary, **you must
re-grant it after every rebuild** (`make app`/`make run` produces a new
binary each time). This is a normal macOS behavior for unsigned/ad-hoc-signed
development builds, not a bug.

## Usage

**Editing a selection:**

1. Select some text in any app (Mail, Notes, Slack, a browser text box,
   your editor — anywhere text can be selected and pasted).
2. Press `⌃⌥⌘E` (or use "Edit Selection…" from the menu bar icon).
3. The panel appears near your cursor, showing "Selection (N chars)".
4. Click an action (Rewrite, Summarize, Fix Grammar, Translate, Reply) or
   type an instruction into the free-form field and press Return.
5. Review the result in the preview, then **Apply** (Return) to paste it back
   in place of your selection, **Copy** to just grab it, or **Retry** to
   re-run the same action.

**Editing the entire document:**

1. Press `⌃⌥⌘E` with nothing selected (or click the "Entire document" segment
   in the panel).
2. AI-Edit selects all (`⌘A`) in the frontmost app, captures the whole text,
   and runs your chosen action over it.
3. Apply pastes the result back over the entire document (select-all, then
   paste).

Press `Esc` at any point to close the panel without changing anything — your
original clipboard contents are always restored afterward.

## Settings

Open via the menu bar icon ▸ **Settings…** (`⌘,`):

- **Shortcut** — re-record the global hotkey.
- **Provider** — GitHub Copilot CLI (only option today); a model text field
  (blank = provider default / "auto"); a Copilot binary path field with a
  **Detect** button and a status dot (green = ready, red = not found/error,
  hover for details).
- **Translation** — target language for the Translate action (default
  "English").
- **General** — Launch at login toggle.

## Troubleshooting

- **"GitHub Copilot CLI was not found"** — install it with
  `npm install -g @github/copilot`, or set the exact binary path in
  Settings ▸ Provider ▸ Copilot path, then click **Detect**/**Check**.
  AI-Edit looks for `copilot` at `/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.local/bin`, and finally falls back to whatever `copilot` resolves to on
  your `PATH`.
- **"GitHub Copilot is not signed in"** — run `copilot` once in a terminal
  and complete the sign-in flow, then retry.
- **Hotkey doesn't fire / conflicts with another app** — open Settings ▸
  Shortcut and record a different combination.
- **Nothing happens / permission dialog keeps appearing** — check
  System Settings ▸ Privacy & Security ▸ Accessibility and make sure AI-Edit
  is toggled on. Remember it needs re-granting after every rebuild (see
  above).
- **The result looks wrong / got pasted into the wrong place** — AI-Edit
  restores your original clipboard about a second after pasting; if you
  interrupt that window (e.g. switch apps very fast) the paste target may be
  off. Retry the action.

## How it works

There's no accessibility-API text extraction and no per-app plugins.
Everything goes through the pasteboard:

1. Snapshot your current clipboard contents (so nothing is lost).
2. Post a synthetic `⌘C` (or `⌘A` then `⌘C` for "entire document") to copy
   the target text, polling the clipboard for a change.
3. Restore your original clipboard immediately — your copy of the captured
   text lives only in memory.
4. Send the captured text to the provider with a prompt built from the chosen
   action.
5. On Apply: put the result on the clipboard, post `⌘V` (or `⌘A` then `⌘V`)
   into the original app, then restore your original clipboard again about a
   second later.

This is why Accessibility permission is required, and why the app briefly
touches your clipboard on each edit (always restoring it afterward).

## Roadmap

- Additional LLM providers behind the existing `LLMProvider` protocol
  (the provider picker already has a "More providers coming soon" slot).
- Right-click / Services menu integration as an alternative to the hotkey.

## License

MIT — see [LICENSE](LICENSE).
