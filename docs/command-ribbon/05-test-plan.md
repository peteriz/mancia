# 05 — Test plan

Two halves: what unit tests must cover, and the manual matrix for the parts
that touch Accessibility, the pasteboard, real windows and synthetic
keystrokes — which unit tests cannot reach and which `CLAUDE.md` therefore
requires be documented by hand.

## Conventions

Tests live in `Tests/ManciaTests/ManciaTests.swift`, which currently holds 91
tests. It uses **swift-testing**, not XCTest:

```swift
import Testing
@testable import Mancia

@Test("Short sentence describing the guarantee")
func someBehavior() {
    #expect(actual == expected, "why this matters when it fails")
}
```

Match that style: a sentence-length `@Test` title stating the guarantee, and a
failure message on any `#expect` whose failure would be ambiguous. Group new
tests under a `// MARK: -` heading, as the file already does.

Anything `@MainActor` needs `@Test @MainActor`. `PanelModel` and `AppSettings`
are both main-actor isolated.

---

## Unit tests

### Placement (stage 2) — ten tests

All against `RibbonPlacement.resolve(height:in:)` with hand-built `Context`
values. Use a 1440×900 screen at origin `.zero` unless stated.

| # | Test | Context | Expect |
|---|---|---|---|
| 1 | Windowed anchors under the menu bar | `visibleFrame` inset 25 top | `.screen`; `frame.maxY == visibleFrame.maxY`; width == `visibleFrame.width` |
| 2 | A zoomed host changes nothing | as 1, host = `visibleFrame` | identical result to 1 |
| 3 | Full-screen anchors to the window with clearance | `topGap = 0`, host = screen | `.hostWindow`; `frame.maxY == screen.maxY - 28` |
| 4 | Auto-hidden menu bar behaves like full-screen | `topGap = 0`, host = a 900×600 window | `.hostWindow`; anchored to that window's `maxY - 28` |
| 5 | Notched display widens the clearance | `topGap = 0`, `safeAreaTop = 37` | clearance 41; `frame.maxY == screen.maxY - 41` |
| 6 | Split View spans the host, not the screen | `topGap = 0`, host = left half | `frame.width == host.width`; `frame.minX == host.minX` |
| 7 | Narrow hosts clamp to the minimum width | host width 320 | `frame.width == 480`, centered on the host |
| 8 | A failed probe falls back to the screen | `hostWindowFrame = nil`, `topGap = 0` | `.hostWindow` anchor, screen geometry, clearance applied |
| 9 | Secondary display keeps the lane on that display | screen origin `(1440, 0)` | `frame.minX >= 1440` |
| 10 | An oversized lane stays on screen | height 2000 | `frame.minY >= screen.minY` |

Add an eleventh guarding the detection threshold itself, because `topGap` is
the rule's hinge and a float comparison:

| 11 | A sub-pixel top gap counts as hidden | `topGap = 0.5` | `.hostWindow` |

### Action resolution (stage 5) — four tests

Against `PanelModel`, `@MainActor`.

- Empty instruction, no pin → `resolvedActionTitle == "Improve"`.
- Non-empty instruction, no pin → `resolvedActionTitle == "Your instruction"`.
- Pinned preset → title is the preset's, regardless of instruction content.
- `runPrimary()` with a pin calls `onPerform` with the pinned preset's action
  and the instruction as the note; without a pin it keeps today's
  empty→`.improve` / typed→`.custom` routing. Assert by capturing the closure's
  arguments — the existing tests in the file already use this pattern for
  model callbacks.

Also assert `reset(hasSelection:charCount:)` clears `pinnedPreset`. Sessions
must not leak a pin across invocations.

### Key commands (stage 7) — two tests

Extend the existing `PanelKeyCommand.resolve` coverage:

- `("1", [.command])` → `.selectPreset(0)`, through `("4", [.command])` →
  `.selectPreset(3)`; `("t", [.command])` → `.toggleTarget`. (Revised after the
  plan shipped — see Q6 in `06-decisions-and-open-questions.md`.)
- `("5", [.command])` → `nil`: a digit past the catalog must not fire the last
  preset.
- A regression guard that the existing mappings are untouched: ⌘A/C/V/X/Z,
  ⇧⌘Z, ⌘W, ⌘,, ⌘Return all still resolve as they do today.

### Settings (stage 8) — two tests

- `ribbonEnabled` defaults to `false` in stage 8 and `true` after stage 9,
  reading from an injected `UserDefaults` — `AppSettings.init` already takes
  one (`AppSettings.swift:84`), so use a fresh suite name, as existing tests do.
- An explicitly stored `false` survives, i.e. the default only applies when the
  key is absent. This mirrors the `confirmWholeDocumentReplace` contract.

### Review preview plumbing (stage 6) — one test

`PanelModel.pendingResultPreview` is cleared by `reset`. The value is set by
`EditCoordinator`, which is not unit-testable here; the clearing is, and a
stale preview leaking into a later session would be a real defect.

---

## Manual matrix

Run the whole matrix at **stage 9**, and rows marked ▲ again at **stage 11**.
Record results in the commit body. Development builds are ad-hoc signed, so
re-grant Accessibility after each `make app` (`CLAUDE.md`).

### Placement

| # | Scenario | Expect |
|---|---|---|
| P1 ▲ | Windowed TextEdit, single display | Lane flush under the menu bar, full width |
| P2 | Zoomed window | Same; lane covers the title bar, not the text |
| P3 ▲ | Native full-screen editor | Lane inset below the top edge; selected text never covered |
| P4 | Full-screen, then pull pointer to the top | Menu bar reveals *above* the lane, does not cover it |
| P5 | System Settings → auto-hide menu bar, windowed app | Behaves like full-screen: window-anchored |
| P6 | Split View, invoke in each half | Lane spans only the focused half |
| P7 ▲ | Second display, host window on it | Lane appears on that display |
| P8 | Drag host between displays, then invoke | Lane follows to the host's display |
| P9 | Unplug a display while the lane is open | Lane repositions, stays on screen |
| P10 | MacBook Pro notched display, full-screen | Clearance clears the camera housing |
| P11 | Tall narrow selection with more room on the right, then on the left | Lane uses the roomier margin; opens away from the text and closes back toward it |
| P12 | Repeat P11 with Reduce Motion enabled | Open and close fade without horizontal travel |
| P13 | Drag the lane from its background at each margin anchor | Lane does not move from its computed anchor |

#### Manual run — 2026-08-03

- P11 and P13 passed in TextEdit on both margin anchors: entry moved away
  from the selected block, close moved back toward it, and background dragging
  did not detach the lane.
- P12 passed with Reduce Motion enabled: both presentation and close used fades
  without horizontal travel.
- A window-edge regression run passed with TextEdit on the right of a
  2560×1440 display: a selection-end anchor stayed horizontally with TextEdit
  instead of centering on the display.

> **Superseding P2.** P2's expectation — that the lane covers the title bar and
> not the text — turned out to be unachievable: a title bar is 28pt and the
> lane is 56pt, growing to ~91pt with the review region open, so a lane hanging
> from the menu bar always reaches into the content of a window sitting flush
> below it. The rule now parks the lane at the foot of its host when the
> resting frame would cover the selection. Two rows replace P2:
>
> | # | Scenario | Expect |
> |---|---|---|
> | P2a ▲ | Window flush under the menu bar, select its first line | Lane parks at the foot of the screen; the selected line stays visible |
> | P2b | Same window, select a line well down the page | Lane stays flush under the menu bar |

### Editing behavior — parity with the panel

The point of these is that the ribbon changed presentation only.

| # | Scenario | Expect |
|---|---|---|
| E1 ▲ | Select a sentence in TextEdit, ⌃⌥⌘E, Return | Sentence improved in place |
| E2 ▲ | Same in a browser textarea (non-Cocoa host) | Works; this is the harshest host |
| E3 | Type an instruction, Return | Runs the instruction, not Improve |
| E4 | Pin Improve from the Action menu, type guidance, Run | Improve template with guidance |
| E5 ▲ | No selection → whole document, Return | Review gate opens; nothing applied yet |
| E6 ▲ | Review gate → `Replace ↵` | Document replaced; version count 2 |
| E7 | Review gate → `Keep editing` | Nothing applied; lane returns to a resting state |
| E8 | Review gate → `Show result` | Full result visible, scrollable; buttons do not move |
| E9 ▲ | Apply, then ← / → | Versions navigate; document matches the counter |
| E10 | Cancel mid-run | Run stops; session stays open; document untouched |
| E11 | Esc at every phase | Session closes; document left as shown |
| E12 ▲ | Clipboard has content → run an edit → check clipboard | Unchanged. The snapshot/restore contract must survive |
| E13 | Sign the provider out, run an edit | Error strip with Details / Copy / Retry; selection untouched |
| E14 | `Copy` on an error | Full error text on the clipboard |

### Keyboard and accessibility

| # | Scenario | Expect |
|---|---|---|
| K1 | Tab through the lane | Target → Action → Direction → Run, visible focus ring on each |
| K2 | ⌘1…⌘4, then ⌘T | Action pins Improve/Sharpen/Plan first/Tighten; ⌘T switches target and is inert with no selection. Neither leaks characters into Direction |
| K3 | ⌘A/C/V/X/Z, ⇧⌘Z in Direction | Standard field editing; undo scoped to the field, never the document |
| K4 | ⌘, then close Settings | Focus returns to Direction — the `focusSeq` path |
| K5 | VoiceOver on, run a full cycle | Phases announced; every control labeled |
| K6 | Reduce Motion on | No slide-in; still ring instead of the comet |
| K7 | Accessibility revoked, then invoke | The existing permission alert, not a crash or silent no-op |
| K8 | Display zoom / larger text | Lane grows; no clipped labels |

### First run

| # | Scenario | Expect |
|---|---|---|
| F1 | Fresh `UserDefaults`, open Settings | Readiness section first; provider internals under Advanced |
| F2 | Fresh install, never granted Accessibility, press the hotkey | Permission alert, then a working session after granting |

---

## What is deliberately not tested automatically

Stated so the gap is a decision rather than an oversight:

- **Synthetic keystroke apply paths.** ⌘C/⌘A/⌘V/⌘Z posted to another app's pid
  cannot be exercised in a unit test; rows E1–E12 are their coverage. This
  matches the existing codebase, which tests `PromptBuilder` and provider
  parsing but not `SelectionCapture`'s event posting.
- **Real window placement.** `RibbonPlacement` is fully tested; the adapter
  that feeds it live `NSScreen` and Accessibility values is covered by P1–P10.
- **SwiftUI layout.** No snapshot testing exists in this repo and this work is
  not the place to introduce it. Geometry is verified by eye against
  [03-visual-spec.md](03-visual-spec.md).
