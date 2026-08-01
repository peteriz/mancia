---
target: Mancia frontend and all dialogs
total_score: 26
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
timestamp: 2026-08-01T07-16-38Z
slug: sources-mancia-panel-editpanelview-swift
---
# Mancia frontend critique

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of system status | 3 | Capture, running, confirm, applied and error are visible; auto-close is easy to miss. |
| 2 | Match system / real world | 3 | Editing language is plain; Settings leaks provider jargon. |
| 3 | User control and freedom | 3 | Cancel, Esc, retry and version navigation exist; immediate selection edits have no preview. |
| 4 | Consistency and standards | 2 | Authored panel beside generic Settings, menu and About surfaces. |
| 5 | Error prevention | 3 | Whole-document confirmation and shortcut validation are sound. |
| 6 | Recognition rather than recall | 2 | Arrow, preset glyph and hidden shortcuts still require learning. |
| 7 | Flexibility and efficiency | 3 | Strong hotkey and repeated-edit loop; no saved custom instructions. |
| 8 | Aesthetic and minimalist design | 3 | Panel is focused; Settings and compressed status actions dilute hierarchy. |
| 9 | Error recovery | 2 | Retry exists, but one-line errors hide detail and remediation. |
| 10 | Help and documentation | 2 | Tooltips and Copilot docs exist; the first-run mental model is absent. |
| **Total** | | **26/40** | **Acceptable** |

## Design Specificity Verdict

Mancia is specific in its core panel and generic in its supporting surfaces. The cream and ink surface, vermilion action, hand mark, near-caret placement and single command row feel authored for fast inline writing edits. Settings is a conventional grouped form, the menu is purely native, and About carries little of the same character. The system feels finished only at the point of use.

The deterministic scan of `Sources/Mancia/Panel/EditPanelView.swift` returned zero findings. This is an unsupported evidence boundary rather than proof of visual quality: the scanner reported `[]` for native SwiftUI markup. Source inspection and committed light/dark screenshots were therefore the reliable visual evidence.

## Overall Impression

The panel is lean, memorable and tuned for repeated work. The largest opportunity is to make the high-anxiety moments—whole-document replacement, setup and provider failure—as calm and deliberate as the happy path.

## What's Working

- The compact near-context panel respects the user's host app and keeps the primary task singular.
- Capture, running, cancel, confirm, applied, iteration and error states are explicitly modeled.
- Global and in-panel keyboard paths make repeat edits genuinely efficient.

## Priority Issues

### P1 — Whole-document confirmation is too thin

**Why it matters:** The highest-blast-radius action is compressed into a one-line character delta.

**Fix:** Expand this state to lead with “Replace entire document?”, retain the delta, and add Show result, Keep editing and Replace document.

**Suggested command:** `$impeccable harden`

### P1 — The default action is under-discoverable

**Why it matters:** An empty field silently means Improve, while the preset affordance currently opens a one-item menu.

**Fix:** Show Improve beside the run control and remove the preset menu until it contains meaningful alternatives.

**Suggested command:** `$impeccable clarify`

### P1 — Settings starts as a provider console

**Why it matters:** First-timers need Shortcut, Accessibility and Copilot readiness before model tuning.

**Fix:** Start with a Ready to edit checklist and move model, reasoning and executable path under Advanced.

**Suggested command:** `$impeccable distill`

### P2 — Contrast and focus polish are weak

**Why it matters:** Small fixed-size secondary text and icon-only plain buttons reduce readability and keyboard confidence.

**Fix:** Raise light-mode contrast, deepen the light accent, add visible focus states, and never rely on the status dot alone.

**Suggested command:** `$impeccable audit`

### P2 — Error recovery is compressed

**Why it matters:** One-line truncation can hide the actual provider/auth/path recovery step.

**Fix:** Pair a short inline message with Details, Copy error and a context-specific recovery action.

**Suggested command:** `$impeccable harden`

## Cognitive Load

Four of eight checks fail: minimal choices in Settings, working-memory support for the invisible capture, progressive disclosure for provider tuning, and one-thing-at-a-time handling in confirmation/error states. The main panel still passes single focus, grouping, chunking and primary hierarchy.

Decision points over four visible options are the status menu, the Copilot Settings section and the model picker.

## Emotional Journey

The panel's immediate near-caret appearance creates confidence. Invisible capture introduces mild uncertainty. The running border and Cancel action handle latency well. Whole-document confirmation is the emotional valley because a terse size delta does not create enough confidence. Applied is satisfying but brief in auto-close mode. Provider errors feel abrupt rather than guided.

## Persona Red Flags

**Alex, power user:** Strong keyboard support, but one preset, no saved instructions and auto-close can constrain iteration.

**Jordan, first-timer:** The arrow does not name Improve; the selection count does not explicitly confirm what was captured; Settings begins with Copilot internals.

**Sam, accessibility-dependent:** Small secondary type, weak light-mode contrast and icon-only controls add friction, although accessibility labels and Reduce Motion support are present.

**Riley, stress tester:** Immediate paste, truncated errors and silent launch-at-login failure reporting leave edge cases hard to inspect.

## Minor Observations

- The hand mark is memorable, but the product name alone does not explain inline rewriting.
- The fixed Settings frame may be tight for localization and larger accessibility text.
- The status menu shortcut is hard-coded even though the shortcut is configurable.
- The standard About panel does not extend the panel's personality.

## Questions to Consider

1. Should the captured target be revealable from the panel, or is scope plus character count the right privacy/compactness balance?
2. Should Improve remain the only named action, or are two to three presets planned soon enough to justify the menu?
3. Should Settings optimize for first-run readiness or ongoing expert tuning as its default view?

## Direction Recommendation

Choose **Warm Desk Instrument**: preserve the cream, ink, hand mark and vermilion while extending that identity to readiness-first Settings, an expanded confirmation state, provider recovery, permission guidance and About. Borrow the Glass HUD's attached confirmation behavior and the Lean Command Slate's explicit keyboard labels.
