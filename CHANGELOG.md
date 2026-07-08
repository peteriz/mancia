# Changelog

All notable changes to Mancia are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/peteriz/mancia/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/peteriz/mancia/releases/tag/v0.1.0
