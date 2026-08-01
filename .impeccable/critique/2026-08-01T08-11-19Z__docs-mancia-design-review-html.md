---
target: docs/mancia-design-review.html (revision 2)
total_score: 25
max_score: 32
na_heuristics: 5,9
p0_count: 0
p1_count: 2
timestamp: 2026-08-01T08-11-19Z
slug: docs-mancia-design-review-html
---
# Mancia design review (revision 2) — critique

Method: dual-agent (A: a5d0bda7879a82a5d · B: a126bbf648bd4bc05)

## Design Health Score

| # | Heuristic | Score | Key issue |
|---|---|---:|---|
| 1 | Visibility of system status | 3 | Selected tab clear; deep in a board there is no indicator of which model you are viewing. |
| 2 | Match system / real world | 4 | Plain editing language, genuine macOS idioms, honest risk framing. |
| 3 | User control and freedom | 3 | Tabs, hash links, print reveals both; no side-by-side view. |
| 4 | Consistency and standards | 3 | Correct ARIA tabs; Recommended badge missing from the tab itself. |
| 5 | Error prevention | n/a | Static Read-mode report; no errable action. |
| 6 | Recognition rather than recall | 3 | Topology map helps; comparison still spans a tab switch. |
| 7 | Flexibility and efficiency | 3 | Roving tabindex, hash restore, print stylesheet. |
| 8 | Aesthetic and minimalist design | 3 | Shell superb; 14 coverage chips and 8-swatch strips dilute. |
| 9 | Error recovery | n/a | No error states possible. |
| 10 | Help and documentation | 3 | Method footer and concept disclaimers set expectations. |
| **Total** | | **25/32 (78%)** | **Good** |

## Design Specificity Verdict

Unmistakably authored for Mancia: committed screenshots, Palette.swift hexes with declared deviations, the real ⌃⌥⌘E shortcut, Copilot/Accessibility recovery dialogs, and register logic derived from the app's own light/dark ramp. Only off-identity note: the cobalt #1e63d9 focus ring.

Deterministic scan: CLI detect.mjs exited 0 with zero findings; the in-page runtime scan reported 160 findings — ~128 text-size hits (mostly by-intent miniature mock content; the 10–11px hits on real prose are legitimate), 3 low-contrast kickers (#686b63 on #ebe8e1 = 4.4:1), 6 line-length (86–98ch prose), plus heuristic pattern rules (cream-palette, kicker-above-heading, nested-cards on mock frames — judged false positives by intent).

## Priority Issues

### P1 — Mock evidence is illegible
Boards are the evidence, set at 8–10px live DOM text; the pivotal REVIEW row is 9px. Detector agrees (~128 size findings). Fix: 11px floor or promote one full-scale review-gate hero per direction.

### P1 — The recommendation is invisible at the decision control
Recommended badge lives only inside #concept-ribbon; the tabs and topology map carry no marker. Fix: badge the tab and topology column.

### P2 — Kicker contrast misses AA
#686b63 on #ebe8e1 is 4.4:1 for small uppercase text. Fix: darken to ~#5d6058-range on that background.

### P2 — Deep link #rail lands nowhere
activate() writes the hash but no element carries those ids; shared URL loads with no scroll. Fix: scrollIntoView on hash restore.

### P2 — No comparison surface for a comparative decision
Differentiating criteria live only in working memory across a tab switch. Fix: compact criteria table between topology map and tabs.

## Persona Red Flags

Sam (accessibility-dependent): 8px live text in rail buttons/scope chips; mock toggles convey state by fill alone; diff washes nearly indistinguishable at 8–9px.

Jordan (first-timer): glyph soup without a legend (⌘1 · ⌘2, ← → Done); "Show result · Replace" reads as one confusing pill; "dark register" jargon; nothing signals mocks are inert until the small disclaimer.

## Minor Observations

- Mocks break the report's own color law: vermilion on settings-nav active state and rail menu/compose beyond Run/Replace.
- Cobalt focus ring is the one non-Mancia hue on the page.
- The settle animation fires on first load, not just tab change.
- Body prose runs 86–98ch; aim under 80.

## Questions to Consider

1. If the boards must be squinted at, are they evidence or texture? Would one full-scale review-gate rendering per direction decide this better than fourteen thumbnails?
2. The verdict is a hybrid (ribbon + rail's review gate) that appears nowhere as a picture. Should revision 3 mock the thing actually being recommended?
