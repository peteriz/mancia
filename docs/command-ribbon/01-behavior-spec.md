# 01 — Behavior specification

> **Superseded in part.** The lane shipped, then a design review of the
> running app removed the per-cell captions ("Target", "Action",
> "Direction") and folded status and iteration in beside Run. The row is one
> line, not two; each control names itself with an icon and its own value.
> See `docs/ARCHITECTURE.md` and `docs/SPEC.md` for what the lane does today.
> Everything else here — the cells, the states, the keyboard model and the
> copy — still holds.

## The shape

The ribbon is a horizontal lane that opens at the top of the screen and reads
left to right as one sentence:

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Target          │ Action          │ Direction                 │          │
│ Selection ⌄     │ Improve ⌄       │ Optional instruction…     │  Run ↵   │
└──────────────────────────────────────────────────────────────────────────┘
```

Four cells. Each has a small caption above a value, except Run, which is the
single accent control. The lane never covers the selected text
(see [02-placement.md](02-placement.md)).

Invocation is unchanged: ⌃⌥⌘E (`KeyboardShortcuts.Name.editSelection`) or the
menu-bar item. `EditCoordinator.start()` is the entry point and its behavior —
show instantly, capture the selection in the background, queue an action fired
during the capture window — is unchanged.

## Cells

### Target

Reflects and sets `PanelModel.scope`.

| `scope` | `hasSelection` | Cell reads |
|---|---|---|
| `.selection` | true | `Selection · 414` (character count) |
| `.document` | either | `Entire document` |
| — | capturing | `Reading…` (menu disabled) |

Menu items: `Selection · N` and `Entire document`. When `hasSelection` is
false, the cell is a static `Entire document` label with no menu — matching
today's `scopeCaption` behavior in `EditPanelView.swift:82`.

Shortcuts ⌘1 (selection) and ⌘2 (document) set it directly; ⌘1 is inert when
`hasSelection` is false.

### Action

**This cell exists to fix the P1 finding that the default action is invisible.**
Today an empty instruction field silently means Improve. The cell makes the
resolved action readable at all times without changing any routing.

The cell displays the *resolved* action, and its menu lets the user pin a
preset explicitly:

| State | Cell reads | Runs |
|---|---|---|
| Direction empty, nothing pinned | `Improve` | `.improve` — today's `runPrimary()` empty-field path |
| Direction non-empty, nothing pinned | `Your instruction` | `.custom(text)` — today's `runPrimary()` typed path |
| A preset pinned from the menu | that preset's title | that preset, with Direction as extra guidance — today's `runPreset(_:)` |

Menu contents: every entry in `PanelPreset.all` (currently just `Improve`),
then a separator, then `Your instruction` which clears the pin.

**Why resolve rather than select.** Making the cell a plain action picker would
mean typing "translate to French" with Action = Improve runs the *Improve*
template with a translation note attached — and Improve's template instructs
the model to preserve meaning, so it would fight the request. Displaying the
resolved action keeps today's proven routing exactly as-is while making it
legible, and pinning stays available for the deliberate
`Improve + extra guidance` case.

Model change required: `PanelModel` gains `var pinnedPreset: PanelPreset?`
(default `nil`, cleared by `reset`). `runPrimary()` gains one branch at the
top:

```swift
func runPrimary() {
    if let pinnedPreset { runPreset(pinnedPreset); return }
    // …existing empty/typed logic, unchanged…
}
```

Add a derived, testable property for the cell's label:

```swift
/// The action the primary control will run right now, as the Action cell
/// shows it. Pure — no side effects, safe to read during layout.
var resolvedActionTitle: String {
    if let pinnedPreset { return pinnedPreset.title }
    return hasCustomInstruction ? "Your instruction" : EditAction.improve.title
}
```

### Direction

The existing instruction `TextField`, with placeholder `Optional instruction…`
(changed from `Describe a change…`, because the Action cell now carries the
"what happens by default" job the old placeholder was straining to do).

Bound to `PanelModel.instruction`. Focused on open. Return triggers
`runPrimary()`. Locked and dimmed while `phase == .running || .confirm`,
matching `fieldLocked` in the current view.

### Run

The single vermilion control. Label `Run ↵`. Calls `runPrimary()`.
Never disabled in `.idle` — an empty field is a valid Improve.

## States

The lane is a vertical stack that grows downward. The command row is always
present; a status strip and the review region appear as phases require.

```
[ command row            ]  ← always
[ status strip           ]  ← when phase != .idle
[ review region          ]  ← when phase == .confirm
```

The command row staying visible during `.running` is deliberate: the user can
read back what they asked for while waiting, which the current panel does not
allow (it dims the whole field).

| `PanelModel.Phase` | Status strip | Notes |
|---|---|---|
| `.idle` | hidden — or `Reading selection…` while `capturing` | Command row live |
| `.running` | `⟳ {runningTitle}…` + `Cancel` | Command row dimmed + locked |
| `.confirm` | `Replace entire document?` + delta | Review region opens; see below |
| `.applied` | `✓ Improved` + version nav when `versionCount > 1` | Auto-close per `postApplyBehavior` |
| `.error` | `✕ {errorText}` + `Details` + `Copy` + `Retry` | See error handling |

### The review gate (`.confirm`)

This is the Proofing Rail's one borrowed idea and the fix for the P1 "the
high-stakes confirmation is too thin" finding. Today the whole decision is one
line of character delta.

The review region shows:

1. **Heading:** `Replace entire document?` — the question leads, not the delta.
2. **Delta:** `3,842 → 3,716 characters`.

   Note the existing helper does *not* produce this string.
   `ApplyConfirmation.summary(originalCharacters:resultCharacters:)` returns
   `"3842 → 3716 chars"` — abbreviated, and its own doc comment says why:
   "it shares the panel's one-line status strip with the Cancel and Replace
   actions." The review region is not that strip, so the abbreviation's
   reason is gone.

   Add a sibling to `ApplyConfirmation`, do not change `summary` (it is
   unit-tested and still correct for compact contexts):

   ```swift
   /// The same size change, spelled out for the review region, which has room
   /// for it. Grouped thousands, because the number is being read as a
   /// magnitude rather than glanced at.
   static func detailedSummary(originalCharacters: Int, resultCharacters: Int) -> String
   ```

   Use `NumberFormatter` with `.decimal` style, or
   `IntegerFormatStyle` with grouping, for the separators — locale-correct
   grouping matters here and hand-rolled string surgery will be wrong in
   several locales.
3. **Preview:** collapsed by default. `Show result ⌄` expands a scrollable,
   read-only text view of the proposed output, max height 220pt. Collapsing
   and expanding must not resize the lane's width or move the buttons.
4. **Actions, right-aligned:** `Keep editing` (secondary) and `Replace ↵`
   (accent). `Keep editing` calls `onCancelRun` — which already discards
   `pendingApply` and returns to a resting phase
   (`EditCoordinator.swift:361`). Return confirms, via the existing
   `handleKeyDown` branch at `EditCoordinator.swift:437`.

v1 does **not** diff. The size delta plus the full result is enough to make the
decision safe, and a real diff is a self-contained follow-up.

### Error handling

The current one-line error truncates and hides the recovery step (P2 finding).
The strip gets three controls:

- `Details` — discloses the full `errorText` in a wrapping area below the
  strip, up to 5 lines, scrollable beyond.
- `Copy` — puts the full error on the pasteboard.
  **Use `NSPasteboard.general` directly here and nothing else.** Do not route
  this through `SelectionCapture`'s snapshot/restore machinery, which exists to
  protect the user's clipboard during an *edit* cycle; a deliberate copy is not
  that.
- `Retry` — calls the existing `onRetry`.

## Keyboard model

The ribbon is the keyboard-first direction; this table is its contract.

| Key | Effect | Where implemented |
|---|---|---|
| ⌃⌥⌘E | Open / refocus | Existing `HotkeyManager` |
| Return | `runPrimary()`, or confirm in `.confirm` | Existing |
| Esc | Close session, host untouched | Existing `onCancel` |
| Tab / ⇧Tab | Move Target → Action → Direction → Run | New, stage 7 |
| ⌘1 / ⌘2 | Target = selection / document | New `PanelKeyCommand` cases |
| ← / → | Version navigation in `.applied` with empty Direction | Existing `handleKeyDown` |
| ⌘, | Settings | Existing |
| ⌘A/C/V/X/Z/⇧⌘Z | Field editing | Existing `PanelKeyCommand` |

Focus lands in Direction on open, and returns there after every phase
transition — carried by the existing `sessionSeq` / `focusSeq` counters, which
already exist for exactly this and must keep working.

## Copy

Exact strings. Sentence case, no terminal periods on labels.

| Element | String |
|---|---|
| Target caption | `Target` |
| Action caption | `Action` |
| Direction caption | `Direction` |
| Direction placeholder | `Optional instruction…` |
| Run | `Run ↵` |
| Capturing | `Reading selection…` |
| Running | `{runningTitle}…` (existing `EditAction.progressLabel`) |
| Cancel | `Cancel` |
| Review heading | `Replace entire document?` |
| Review preview toggle | `Show result` / `Hide result` |
| Review secondary | `Keep editing` |
| Review primary | `Replace ↵` |
| Applied | `Improved` |
| Error actions | `Details` · `Copy` · `Retry` |

Never name the provider in ribbon copy; the provider's own error text may name
itself and that is fine.
