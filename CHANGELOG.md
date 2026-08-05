# Changelog

All notable changes to Mancia are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The swoosh — the comet that runs a control's border while its action is in
  flight — now takes a color of your choosing, set in Settings under Editing.
  It was the one color in the lane with no meaning riding on it: it says
  "running", which the control's own state already says.

### Fixed

- Model-specific reasoning choices now refresh from Copilot CLI at launch and
  after Settings closes. ACP sessions explicitly apply the saved model and
  effort, preventing Copilot's prior session state from overriding them.

## [0.3.1] - 2026-08-04

### Changed

- Refresh the README ribbon guidance and screenshot so the documented actions
  match the current interface.

## [0.3.0] - 2026-08-04

### Fixed

- Run did nothing when clicked. Its label was hidden so the drawn word could be
  reinstated outside the dimming `disabled` applies, and a plain button's hit
  region *is* its label — so the lane's one primary control rendered perfectly
  and answered no mouse. The label is now transparent rather than hidden, and
  carries the hit shape itself. Return always worked, which is why this went
  unnoticed: it is the mouse path that was dead, from every action.
- About reported 0.1.0 while the shipped bundle was 0.2.2. The panel now reads
  `CFBundleShortVersionString` from the bundle, so it follows the version the
  release workflow writes instead of a Swift literal that had to be remembered.
  `Support/Info.plist` is now the only place a version number lives, and tests
  fail if its two version keys or the changelog's newest release drift apart.

### Changed

- Custom instructions stay tucked away until requested, while the ribbon keeps
  its core actions visible and exposes keyboard shortcuts on hover.
- The model picker groups models by provider family and orders versions newest
  first without changing which model is recommended.
- The ribbon can be dragged from its background and keeps the user's chosen
  position while its contents resize.
- The menu says "About Mancia" and "Quit Mancia", matching the spec and the
  platform convention.
- The ribbon answers a selected *block* as well as it answered a selected
  line. A paragraph or quote too tall to leave room at either end used to send
  the lane back to the menu bar, on top of the head of the very block it was
  invoked on; it now stands in the margin beside the block, on the roomier
  flank, level with its middle and as wide as that margin can hold — covering
  no text at all.
- A block with no margin either side settles at whichever of its ends has more
  room, rather than making the trek to the top of the screen. The predictable
  resting place is now the last resort, kept for a selection with nowhere at
  all beside it.

### Added

- `--about-check` opens the About panel, checks the version it reports, and
  clicks its red close button on both a first open and a reopen — the title bar
  a unit test cannot reach.
- `--ribbon-click-check` clicks the lane's Run control the way a user does and
  asks the model what ran, with the default action and with a preset pinned. A
  control that draws but takes no hits is invisible to `swift test`; this is
  the check that would have caught it.

## [0.2.2] - 2026-08-03

### Changed

- The ribbon stays with the text it is editing. A result longer than what it
  replaced no longer ends up underneath the lane: the placement re-resolves
  when the lane would cover the new span, and holds still when it would not,
  so a move only happens when it buys visibility.
- A selection made mid-session moves the lane with it, re-probing the host
  window so a selection in another window — or another app on another
  display — is answered beside the right text on the right screen.
- The default "flash and close" beat now also requires the lane to still hold
  key, so clicking back into the host app to select the next passage keeps the
  session open instead of closing it mid-iteration.

## [0.2.1] - 2026-08-02

### Changed

- The running signal on Run reads at a glance: the travelling light keeps a
  bright head over the accent fill, trails a vermilion glow onto the lane, and
  sits over a steady ember so the state holds in every frame rather than only
  where the light happens to be. It also travels by path length instead of by
  angle, which holds one speed the whole way around a control wider than it is
  tall, and the lap is quicker — 1.6s to 0.925s. Reduce Motion keeps the ember
  and drops the movement.
- README leads with a ribbon image that is now reproducible: `make shot`
  renders the shipping `RibbonView` off screen, so the hero can be redrawn
  after any change to the lane rather than re-shot by hand.

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

[Unreleased]: https://github.com/peteriz/mancia/compare/0.3.0...HEAD
[0.3.0]: https://github.com/peteriz/mancia/compare/0.2.2...0.3.0
[0.2.2]: https://github.com/peteriz/mancia/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/peteriz/mancia/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/peteriz/mancia/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/peteriz/mancia/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/peteriz/mancia/releases/tag/0.1.0
