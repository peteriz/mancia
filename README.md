<p align="center">
  <img src="docs/assets/mancia-logo.png" alt="Mancia logo" width="240">
</p>

# AI-Edit

AI-Edit is a small macOS menu bar utility that puts an AI text edit within a
keystroke of anywhere you type. Press a global hotkey in any app, and a
compact Writing Tools-style panel appears next to your text caret offering
quick actions — Proofread, Rewrite, Summarize — or a free-form instruction
you type yourself. The result is applied in place immediately; iteration
arrows (← 2/3 →) let you flip between the original and every result you've
generated, and you can chain further edits in the same session. No
copy-pasting into a chat window, no context switch.

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
- **Floating panel** appears next to your text caret (centered on screen for
  whole-document edits) without stealing focus from the app you're editing in.
- **Three built-in actions** — Proofread, Rewrite, Summarize — plus a
  free-form "Describe your change…" field for anything else.
- **Two scopes** — edit just the current selection, or the entire document
  (select-all under the hood).
- **Applied instantly, reversible** — the result lands in your document right
  away; iteration arrows with a **2/3-style counter** navigate between the
  original and every generated version, and **Done** (or Esc) keeps whichever
  is showing.
- **Cyclical sessions** — the panel stays visible and on top the whole time
  (no flicker during applies), so you can chain edits (proofread, then "make
  it sound excited", …) before closing. While a request runs, the panel shows
  a spinner and disables everything except Cancel.
- **Menu bar only** — no Dock icon, no app windows to manage.
- **GitHub Copilot CLI provider** — uses your local `copilot` binary with
  optional model and reasoning-effort settings.

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
3. The panel appears next to your caret, with a "Selection · N chars" caption
   (a small menu on the caption switches to "Entire document").
4. Click an action (Proofread, Rewrite, Summarize) or type an instruction
   into "Describe your change…" and press Return.
5. While the request runs, the panel shows a spinner with the action name;
   everything else is disabled except **Cancel**. The result then replaces
   your selection immediately (the panel stays visible throughout), and the
   status row shows iteration arrows with a counter (e.g. `← 2/2 →`) plus
   **Done**. Version 1 is always your original text.
6. The session stays open: run another action or type another instruction to
   edit the current result again (each result appends an iteration; going
   back and running a new action drops the versions after the current one),
   or press **Done**/`Esc` to finish, keeping whichever version is showing.

**Editing the entire document:**

1. Press `⌃⌥⌘E` with nothing selected — the panel opens centered on screen
   with an "Entire document" caption.
2. For every action, AI-Edit selects all (`⌘A`) in the frontmost app,
   captures the whole text (picking up any manual edits you made between
   actions — a changed document starts a fresh iteration history), runs your
   chosen action, and pastes the result back over the document. The iteration
   arrows re-apply the tracked versions.

Press `Esc` at any point to close the session — your original clipboard
contents are always restored after each capture/apply.

## Settings

Open via the menu bar icon ▸ **Settings…** (`⌘,`):

- **Shortcut** — re-record the global hotkey.
- **GitHub Copilot CLI** — a **Model** picker
  (populated from the Copilot CLI's cached model list in `~/.copilot/data.db`;
  "Default" = provider default); a **Reasoning effort** picker ("Default" =
  no flag, otherwise passed as `--reasoning-effort`, narrowed to the levels
  the selected model supports); a Copilot binary path field with a
  **Detect** button and a status dot (green = ready, red = not found/error,
  hover for details).
- **General** — Launch at login toggle.

## Troubleshooting

- **"GitHub Copilot CLI was not found"** — install it with
  `npm install -g @github/copilot`, or set the exact binary path in
  Settings ▸ GitHub Copilot CLI ▸ Copilot path, then click **Detect**/**Check**.
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
   the target text, polling the clipboard for a change. Keystrokes are
   posted directly to the target app's process (`CGEvent.postToPid`), so the
   floating panel never has to hide out of their way.
3. Restore your original clipboard immediately — your copy of the captured
   text lives only in memory.
4. Send the captured text to the provider with a prompt built from the chosen
   action.
5. Apply immediately: put the result on the clipboard, post `⌘V` (or `⌘A`
   then `⌘V`) into the original app, then restore your original clipboard
   again about a second later.
6. Iteration navigation replaces the document text with the chosen version:
   for selections, `⌘Z` (undo of the outstanding paste, which also restores
   the selection) followed by `⌘V` with that version; for whole-document
   edits, `⌘A` + `⌘V`. Repeat edits replace the previous paste the same way,
   so exactly one paste stays outstanding over the session original.

This is why Accessibility permission is required, and why the app briefly
touches your clipboard on each edit (always restoring it afterward).

## License

MIT — see [LICENSE](LICENSE).
