# Changelog

All notable changes to Mancia are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-02

### Added

- Command ribbon: a slim **Target · Action · Direction · Run** lane that
  replaces the floating edit panel. It sits against the text being edited —
  just under the selection, or just over it when the selection is near the
  foot of its window — and falls back to a predictable resting place under
  the menu bar or the host's title bar when there is no selection or no room
  beside one.
- Ribbon keyboard model: Return runs, Esc closes, Tab cycles the cells,
  `cmd-1`…`cmd-4` pin the four presets, `cmd-0` unpins, and `cmd-T` switches
  the target between selection and whole document.
- Three presets that restructure rather than reword, none of which may invent
  requirements: **Sharpen** (goal first, constraints and success criteria as
  explicit lines, concrete anchors kept verbatim), **Plan first** (reframes an
  implementation request as an investigate-then-plan request), and **Tighten**
  (the shortest faithful version, dropping filler but never a requirement).
- Provider readiness is surfaced in Settings and in the ribbon's status strip.

### Changed

- The ribbon keeps the target app focused for the whole session, so synthetic
  keystrokes go straight to the host's pid and the old hide/reveal dance is
  gone.
- README and architecture/spec docs are updated for the ribbon, including a
  new ribbon screenshot in place of the panel screenshots.

## [0.1.1] - 2026-07-28

### Changed

- README: the panel screenshot is re-captured from the current single-command-row
  panel and now ships in both appearances, switching with the reader's
  light/dark theme.
- README: the project title is centered with the logo and badges above it.

## [0.1.0] - 2026-07-08

### Added

- Menu bar app (no Dock icon) that edits text inline in any frontmost app using
  pasteboard snapshots and synthetic `cmd-C` / `cmd-A` / `cmd-V`.
- Global hotkey (default `Control-Option-Command-E`) and an **Edit Selection…**
  menu item that both open a compact floating panel near the cursor.
- Panel actions: a one-tap **Improve** action (proofread and rewrite combined)
  plus a free-form custom instruction field. Prompt templates for Proofread,
  Rewrite, and Summarize are also reachable through the debug CLI.
- Edits apply immediately in place, with iteration history and `←` / `→`
  navigation between the original and each generated version.
- Selection scope and whole-document scope (select-all when nothing is
  selected), with a configurable post-apply behavior (flash-and-close or
  stay-open).
- GitHub Copilot CLI provider with model and reasoning-effort pickers populated
  from the CLI's cached model list.
- Settings window: global shortcut recorder, Copilot binary path with detection,
  and launch-at-login toggle.
- Clipboard is snapshotted and restored around each capture and paste.
- Accessibility permission handling with a System Settings deep link.
- Packaging: `make app` builds `Mancia.app`, `make dmg` builds a
  drag-to-install disk image.
- Debug/E2E hooks: `--provider-check` and `--complete <action>`.

[Unreleased]: https://github.com/peteriz/mancia/compare/0.2.0...HEAD
[0.2.0]: https://github.com/peteriz/mancia/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/peteriz/mancia/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/peteriz/mancia/releases/tag/0.1.0
