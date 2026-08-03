# 04 — Build plan

Eleven stages, each a single commit that builds, passes `make test`, and leaves
the app usable. Stages 1–3 ship no visible change; stages 4–8 build the ribbon
behind a setting; stage 9 flips the default; stages 10–11 remove the old panel
and update the docs.

Do not reorder. Stage 2 in particular must land before any UI exists, because
the placement rule is the direction's main risk and it is cheapest to get wrong
in a test file.

Run `make build` after every stage and `make test` before every commit.

---

## Stage 1 — Palette contrast fixes

**Ships alone.** Changes the current panel's appearance; that is intended and
is the P2 finding from the design review.

**Files:** `Sources/Mancia/Panel/Palette.swift`

- `accent` light `0xD8513A` → `0xC2412C`
- `textSecondary` light `0x857866` → `0x6E6250`
- `textFaint` light `0xA2957F` → `0x756850`
- Add an internal `Color(hex:)` helper (or `Palette.color(_:)`) so
  `RibbonPalette` can reuse the conversion in stage 5 instead of duplicating
  the private `nsColor(_:)`.
- Leave every dark value alone — the dark column already passes.

**Acceptance:** panel looks the same in dark appearance; in light appearance
the run button, captions and placeholder are visibly deeper. Ratios per
[03-visual-spec.md](03-visual-spec.md).

**Manual test to document:** open the panel in light and dark, confirm the
accent still reads as vermilion and not brown.

---

## Stage 2 — `RibbonPlacement`, pure and tested

**Files:** `Sources/Mancia/Ribbon/RibbonPlacement.swift` (new),
`Tests/ManciaTests/ManciaTests.swift`

Implement exactly the resolver in [02-placement.md](02-placement.md). No
AppKit import — `CoreGraphics` only. Add all ten table cases from that document
as `@Test` functions.

**Acceptance:** ten new passing tests; no other file changes; nothing visible
in the app.

---

## Stage 3 — `HostWindowProbe`

**Files:** `Sources/Mancia/Ribbon/HostWindowProbe.swift` (new)

Accessibility read of the frontmost app's focused-window frame, AX→AppKit
coordinate flip, ~100ms messaging timeout, `nil` on every failure path.

If the coordinate flip in `SelectionCapture.selectionScreenRect()`
(`SelectionCapture.swift:127`) can be factored into a shared internal helper
without disturbing its callers, do that; otherwise leave it and mirror the
convention with a comment pointing at it.

**Acceptance:** builds; a temporary `--probe-window` debug hook (see
`DebugCLI.swift` for the existing pattern) prints a plausible frame for
Safari, Notes and a full-screen window. **Remove the hook before committing**
unless `DebugCLI` is where it genuinely belongs long-term.

**Manual test to document:** frames reported for a windowed app, a zoomed app,
a full-screen app, and an app on a secondary display.

---

## Stage 4 — `RibbonWindow`

**Files:** `Sources/Mancia/Ribbon/RibbonWindow.swift` (new)

The `NSPanel` host. Model it on `EditPanel.swift`, which already solved most of
this — copy its window configuration rather than rediscovering it:

- Same style mask (`[.nonactivatingPanel, .titled, .fullSizeContentView]`),
  hidden title, hidden standard buttons. **Do not switch to `.borderless`**;
  the current mask is proven to accept key status with the
  `canBecomeKey` override and changing it risks a focus regression for no gain.
- `level = .floating`, `isOpaque = false`, `backgroundColor = .clear`,
  `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`,
  `isFloatingPanel = true`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
- `isMovableByWindowBackground = false` — unlike the panel, the lane has a
  computed home and must not be draggable out of it.
- Port `KeyablePanel` wholesale: `canBecomeKey`, `cancelOperation`,
  `sendEvent` key interception, `performKeyEquivalent` +
  `PanelKeyCommand` dispatch, and the field undo manager. This class is the
  reason ⌘A/⌘C/⌘V/⌘Z work inside the field in a menu-bar-only app; losing it
  would be a silent, painful regression.

Sizing inverts the panel's: **width comes from placement, height from
content.** Ask the hosting view for its fitting height at the resolved width,
then `setFrame(_:display:animate:)`.

Add `func reposition()` for height changes and screen-parameter changes;
subscribe to `NSApplication.didChangeScreenParametersNotification` while
visible only.

**Acceptance:** a temporary call site shows an empty ink lane in the right
place in all four placement scenarios. Entrance and exit animations per
[03-visual-spec.md](03-visual-spec.md).

---

## Stage 5 — Command row

**Files:** `Sources/Mancia/Ribbon/RibbonView.swift` (new),
`Sources/Mancia/Ribbon/RibbonPalette.swift` (new),
`Sources/Mancia/Panel/PanelModel.swift`

- `RibbonPalette` per [03-visual-spec.md](03-visual-spec.md), using stage 1's
  hex helper.
- `RibbonView` binding the existing `PanelModel`: Target, Action, Direction,
  Run, at the geometry in the visual spec.
- `PanelModel` gains `pinnedPreset`, the `runPrimary()` branch, and
  `resolvedActionTitle` per [01-behavior-spec.md](01-behavior-spec.md). Clear
  `pinnedPreset` in `reset(hasSelection:charCount:)`.

**Acceptance:** the lane renders all four cells; Return and Run both call
`runPrimary()`; the Action cell's label tracks typing; scope menu works.
Add unit tests for `resolvedActionTitle` and the `runPrimary()` pin branch.

---

## Stage 6 — Status strip and review region

**Files:** `Sources/Mancia/Ribbon/RibbonView.swift`,
`Sources/Mancia/Ribbon/RibbonReviewView.swift` (new)

Status strip for `.running` / `.applied` / `.error`, and the expanded review
region for `.confirm`, both per [01-behavior-spec.md](01-behavior-spec.md).

Reuse, do not reimplement. Four small components live in `EditPanelView.swift`
and are all `private` to that file: `SwooshBorder` (:454), `GhostButton`
(:393), `AccentButton` (:420), and `PresetMenuButton` (:355).

Move them into `Sources/Mancia/Ribbon/RibbonControls.swift` as **internal**
types and have `EditPanelView` import them from there — one definition, two
call sites, no duplication to reconcile at stage 11.

Also add `ApplyConfirmation.detailedSummary(originalCharacters:resultCharacters:)`
per [01-behavior-spec.md](01-behavior-spec.md) — the existing `summary` is
abbreviated for the old one-line strip and stays as-is for compact contexts.
Add a unit test for the new formatter alongside the existing `summary` tests.

**This stage needs the result text, which `PanelModel` does not currently
carry.** `EditCoordinator` holds it privately in `pendingApply`
(`EditCoordinator.swift:41`). Add `var pendingResultPreview: String = ""` to
`PanelModel`, set it in `presentConfirmation` alongside the existing char
counts (`EditCoordinator.swift:229`), and clear it in `reset` and wherever
`pendingApply` is cleared. **This is the only permitted `EditCoordinator`
change in this stage** — do not touch the apply or version logic.

Every height change calls `RibbonWindow.reposition()`.

**Acceptance:** all five phases render; the review region expands and collapses
without moving the buttons; `Keep editing` returns to a resting phase; Return
confirms; error `Copy` puts the full text on `NSPasteboard.general`.

---

## Stage 7 — Keyboard model

**Files:** `Sources/Mancia/Panel/PanelKeyCommand.swift`,
`Sources/Mancia/Ribbon/RibbonView.swift`,
`Sources/Mancia/EditCoordinator.swift`

- `PanelKeyCommand` gains `.selectPreset(Int)` (⌘1…⌘4) and `.toggleTarget`
  (⌘T); add cases to its `resolve` and tests. Follow the existing shape exactly
  — this type is already unit-tested and the tests should extend, not change.
  (The digits were ⌘1/⌘2 = target as originally planned; revised on request
  after the presets landed. See Q6 in doc 06.)
- `RibbonWindow` routes them to the model.
- Tab order Target → Action → Direction → Run via a `@FocusState` enum.
- Focus lands in Direction on `sessionSeq` / `focusSeq` change, as today.
- ⌘T is inert when `hasSelection == false`, and both are inert while a request
  is in flight — they are resolved above the SwiftUI tree, so they never see
  the `disabled` on the cells.

Route ⌘Z through `KeyablePanel`: the instruction field's undo manager gets
first refusal, then `EditCoordinator.undoLastVersion()` restores the previous
applied version. Do not add arrow-key or on-screen iteration navigation.

**Acceptance:** the full keyboard table in
[01-behavior-spec.md](01-behavior-spec.md) works, verified by hand, with
focus rings visible on every stop.

---

## Stage 8 — Settings: readiness first, ribbon second

**Files:** `Sources/Mancia/Settings/SettingsView.swift`,
`Sources/Mancia/Settings/AppSettings.swift`

Fixes the third P1: Settings currently opens on provider internals.

- **Readiness section, first:** Shortcut (with the existing
  `ShortcutRecorderView`), Accessibility (granted / not, with a button to open
  System Settings via the existing `Permissions` helpers), and provider
  connectivity. Each a check line with a real state, not a label.
- **Ribbon section:** `Confirm document edits` (the existing
  `confirmWholeDocumentReplace`) and `After applying` (the existing
  `postApplyBehavior`).
- **Advanced, collapsed:** model, reasoning effort, executable path — every
  control that is there today, moved, not removed.
- New setting `ribbonEnabled: Bool`, default **false** in this stage. Key
  `"ribbonEnabled"`. Follow the existing `didSet`-persists pattern in
  `AppSettings`.

**Acceptance:** first-run Settings answers "am I ready to edit?" above the
fold; every existing control is still reachable; the new toggle switches
presentation on next invocation.

---

## Stage 9 — Wire both presentations, flip the default

**Files:** `Sources/Mancia/EditCoordinator.swift`,
`Sources/Mancia/Ribbon/RibbonWindow.swift`

Introduce a minimal internal protocol so the coordinator owns one reference:

```swift
@MainActor
protocol EditPresentation: AnyObject {
    func show()
    func close()
    func focus()
    var onKeyDown: ((NSEvent) -> Bool)? { get set }
    var onOpenSettings: (() -> Void)? { get set }
}
```

`EditPanel` and `RibbonWindow` both conform. `EditCoordinator` picks one at
`start()` from `settings.ribbonEnabled`. Note `show()` loses its `placement:`
parameter — the panel keeps its own `instantPlacement()` internally, and the
coordinator's `instantPlacement()` helper (`EditCoordinator.swift:113`) moves
into `EditPanel`.

Then flip `ribbonEnabled` to default **true**.

**Acceptance:** both presentations work; the toggle switches cleanly; no
behavior difference in capture, apply, versions or auto-close between them.
This is the stage to run the full manual matrix in
[05-test-plan.md](05-test-plan.md).

---

## Stage 10 — Soak

No code. Use the ribbon as the default for real work across at least: a native
Cocoa editor, a browser textarea, a full-screen editor, and a second display.
Record anything that felt wrong. Fix only what is a defect; note the rest as
follow-ups rather than widening this work.

---

## Stage 11 — Remove the panel

**Files:** delete `Sources/Mancia/Panel/EditPanel.swift` and
`Sources/Mancia/Panel/EditPanelView.swift`; edit
`Sources/Mancia/EditCoordinator.swift`,
`Sources/Mancia/Settings/AppSettings.swift`,
`Sources/Mancia/Settings/SettingsView.swift`, `docs/ARCHITECTURE.md`,
`docs/SPEC.md`

- Delete both files and the `EditPresentation` protocol if `RibbonWindow` is
  now the only conformer — a protocol with one implementation is indirection,
  not abstraction.
- Remove `ribbonEnabled` and its Settings row.
- Move anything still needed out of the deleted files first. Stage 6 already
  moved the shared controls to `RibbonControls.swift`; what remains in
  `EditPanel.swift` is `KeyablePanel`, which stage 4 ported. Confirm with
  `rg` rather than assuming, and check `PresetMenuButton` still has a caller —
  if the ribbon's Action cell replaced it, delete it too.
- `Palette.swift`, `PanelModel.swift`, `PanelKeyCommand.swift` and
  `PanelPreset.swift` **stay**. Consider renaming `Panel/` to `Editing/` only
  if it is a pure `git mv` plus import-free rename; if it churns more than
  that, leave it and say so.
- Update `docs/ARCHITECTURE.md` — the component map, the core flow, and the
  panel description — and `docs/SPEC.md`'s repository layout and core flow.

**Acceptance:** `make test` passes; `rg 'EditPanel|EditPanelView'` returns
nothing outside the design review HTML and this planning directory; the
architecture docs describe what the code now does.

---

## Commit messages

Follow the repo's existing style (see `git log`): a short imperative subject
naming the change, no scope prefix. For stages touching Accessibility,
pasteboard or synthetic keystrokes — stages 3, 6 and 9 — the body must record
what was manually tested, per `CLAUDE.md`.
