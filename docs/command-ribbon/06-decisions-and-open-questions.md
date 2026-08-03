# 06 — Decisions and open questions

## Settled — do not relitigate

These were decided in the design review and the conversation that followed it.
Each is written here with its reason so the next agent can build confidently
rather than re-deriving the argument.

| Decision | Reason |
|---|---|
| **Command Ribbon over Proofing Rail** | The ribbon has one predictable home and no cross-app anchoring risk. The rail is heavier than a two-word tweak deserves; it is kept as a possible later document mode |
| **Inline Selection Lens rejected** | The user rejected the inline model outright; its cobalt palette also sat outside Mancia's identity |
| **Hybrid placement** | Screen-anchored keeps the "one place" promise for the common case; window-anchored is the only way not to cover text in a full-screen Space. See [02-placement.md](02-placement.md) |
| **Lane runs the fixed dark register** | The lane is chrome adjoining the menu bar. A cream bar under a dark menu bar reads as a detached foreign object |
| **Action cell shows the *resolved* action, with optional pinning** | Makes the invisible default visible (the P1 finding) without changing today's proven routing. A plain action picker would run Improve's "preserve meaning" template against a translation request |
| **Review gate borrows from the rail; no diff in v1** | Size delta plus a full collapsible preview makes the decision safe. A real diff is a self-contained follow-up, not a blocker |
| **Vermilion exactly once per surface** | The accent only means "this is the commit" if nothing else wears it |
| **Staged migration, panel deleted at the end** | Keeps every stage shippable. Carrying two UIs permanently would be bloat in an app this size, hence the explicit deletion stage |
| **Three palette contrast fixes ship first, alone** | They change the existing panel too; isolating them makes any regression attributable |

## Open questions

Answer these before or during the stage named. Where there is a
recommendation, it is the default to take if the user does not weigh in.

### Q1 — Full width on very wide displays (stage 4)

The mock shows a full-width lane and that is what
[02-placement.md](02-placement.md) specifies. On a 5K or ultrawide display a
full-width lane means ~5000pt of mostly empty ink, and the Run control ends up
a long way from the Direction field the user just typed in.

**Recommendation:** add a `maximumWidth` of ~1200pt to `RibbonPlacement`,
centered on the host when it clamps. This is a two-line change to the resolver
and one extra test. It preserves "one predictable place" — the lane is still
top-centered — while keeping the command sentence readable as a sentence.

**Ask the user before implementing**, since it departs from the approved mock.

### Q2 — Auto-close in the ribbon (stage 9)

`postApplyBehavior` defaults to `.hybrid`: flash "Improved", auto-close after
1200ms, any keypress cancels the close (`EditCoordinator.swift:414`). That was
tuned for a small panel next to the caret.

The lane is at the top of the screen, further from where the user is looking,
so the flash may be missed entirely — the design review's own critique flagged
auto-close as easy to miss even in the panel.

**Recommendation:** keep `.hybrid` as the default and the 1200ms value for now;
note in stage 10's soak whether the applied state is being missed. Changing the
timing is a one-line follow-up once there is real evidence, and guessing now
would be guessing.

### Q3 — `Panel/` directory name after the panel is gone (stage 11)

`Palette`, `PanelModel`, `PanelKeyCommand` and `PanelPreset` all stay, in a
directory named after a thing that no longer exists.

**Recommendation:** rename `Panel/` → `Editing/` only if it is a clean
`git mv` plus type renames with no behavioral edit. If the rename churns the
diff enough to obscure the deletion, leave it and open a follow-up. Say which
you did.

### Q4 — Does the lane need a visible dismiss affordance? (stage 10)

Esc closes it, and that is the only way besides finishing an edit. The panel
had the same constraint and it never surfaced as a complaint, but the panel was
adjacent to the user's gaze and obviously transient; a bar pinned under the
menu bar may read as more permanent.

**Recommendation:** leave it out of v1. Watch for it in the soak. Adding a
close control is easy; removing one that people have learned is not.

### Q5 — Provider readiness in Settings (stage 8)

The readiness checklist needs a real provider-connectivity state, not a label.
`CopilotCLIProvider` has a check path behind `swift run Mancia --provider-check`
(see `DebugCLI.swift`), but wiring a live status into the Settings window may
need a small addition to `LLMProvider`.

**Recommendation:** if the protocol needs a new requirement, add
`func readinessCheck() async -> Result<Void, Error>` with a default
implementation returning success, so the multi-provider roadmap is not
constrained by a Copilot-shaped API. If that turns out to be more than a small
change, ship stage 8 with shortcut and Accessibility rows only and open a
follow-up for the provider row rather than widening the stage.

## Q6 — the digit shortcuts, revised after the plan shipped

**Settled during the design review:** ⌘1 and ⌘2 set the target to the selection
and to the whole document (doc 01, "Target"; stage 7 of the build plan).

**Changed on request, after the presets landed:** ⌘1…⌘4 now pin the four
presets — Improve, Sharpen, Plan first, Tighten — and the target moved to ⌘T,
which switches between its two states.

**Why the digits are worth more to the presets:** there are four of them and
picking one is the frequent move, whereas the target is usually right already —
the session opens aimed at whatever the user had selected. A two-state control
is served just as well by one key.

**Why ⌘T and not ⌘⇧1 / ⌘⇧2:** `charactersIgnoringModifiers` applies Shift, so a
shifted digit arrives as a layout-dependent symbol (`!` on US, something else
elsewhere) and the mapping would stop being a pure function of the character.
`T` is stable across layouts, and Mancia has no Edit or File menu for it to
collide with.

**Consequence worth knowing:** these shortcuts are resolved by `KeyablePanel`,
above the SwiftUI tree, so the `disabled` that greys the cells out while a
request runs is invisible to them. `PanelModel.isLocked` is what actually holds
them off, and the mutating entry points check it themselves.

## Q7 — what bounds the selection-fit test, raised in review of #33

**Raised by the reviewer:** with a menu bar present `host` is `visibleFrame`, so
the `floor` and `ceiling` that `choose()` measures against are the screen's, not
the host window's. A selection near the foot of a *short* window therefore
"fits below" on the screen, and the lane is placed outside its own host.

**Kept as it is: the screen is the right bound.** The lane is a floating
overlay and is not clipped to its host. Bounding the fit by the window would
send it back to the resting anchor under the menu bar precisely when the
selection sits near the window's foot — which is the long trek the
selection-anchored rule was added to remove. Spilling a little past a short
window's bottom edge keeps the lane 8pt from the words; retreating to the menu
bar does not.

**The growth case is guarded, and was checked rather than assumed.** The worry
worth taking seriously is `projectedHeight`: a review gate opening later could
grow the lane down into the selection. Probed with a 250pt host window high on a
1440×900 display and a selection near its foot —

```
h=50   belowChosen=yes  frame.y=562..612  coversSelection=no
h=200  belowChosen=yes  frame.y=412..612  coversSelection=no
h=260  belowChosen=yes  frame.y=352..612  coversSelection=no
```

— the lane never covers the selection, even 60pt past the projected height,
because `choose()` reserves `projectedHeight` before picking `.belowSelection`
and the clamp floor (`screen.minY`) sits a further ~60pt below `floor`
(`visibleFrame.minY`).

**Consequence worth knowing:** this is a deliberate choice that reads like an
oversight, so the reasoning lives in a comment in `choose()`. Doc 02 gives no
ruling either way — it predates the selection-anchored rule and defines only the
resting anchors.

## Q8 — where a lane goes when the selection is too tall for either end

**Raised by use:** the selection-anchored rule answers a *line* well and a
*block* badly. `choose()` needed `projectedHeight` — 200pt — clear at one end
of the selection, so a selected paragraph, quote or code block on a 900pt
display left it nothing at either end and it fell back to the resting anchor.
That is the long trek Q7 exists to prevent, arriving by another route, and it
lands the lane *on* the head of the block it was invoked on.

**A tall selection is usually a narrow one.** A paragraph is a column of text
with a margin either side of it, and a lane standing in that margin covers no
text at all — strictly better than any position at either end, which is why the
margin is tried before the cramped end and before the resting anchor. Two new
anchors, `.leftOfSelection` and `.rightOfSelection`: the roomier flank wins, the
lane takes the widest lane that margin can hold (never reaching back across the
text), and it sits level with the middle of the block, where the eye already is.
It is the one anchor whose width is not the host's, and the one that grows
symmetrically — along a margin it owns outright there is nothing to creep over.

**A block with no margin either gets the cramped end, not the menu bar.** Full
width *and* too tall for `projectedHeight` — a wide editor, a long selection —
leaves only the ends, and the rule now takes the roomier one provided it can
hold the lane as it opens (`crampedRoom`, one command row). The trade Q7 could
answer cleanly and this cannot: a review gate opening on a cramped lane *can*
reach back over the far end of the block, because the clamp will not let it run
off the screen. That is accepted deliberately. The gate only opens on a
whole-document run, which from a selection means one the user retargeted by
hand, and the alternative — covering the *head* of the same block from the far
end of the screen, on every run — is worse for every other case.

**Still the resting anchor when nothing is left:** everything on screen
selected, or a selection scrolled clean out of the band. There every position
covers the text as thoroughly as the next, so predictability wins.

**Consequence worth knowing:** `Anchor` now has six cases, and anything
switching over it — the corner treatment in `RibbonView.shape`, the entrance
direction in `Anchor.entranceDirection` — has to answer for the horizontal pair.
The entrance travel stays the lane's *height* on all six: vertically that is the
distance that hides the lane behind its edge, horizontally it is a short slide,
where the lane's own 600pt-plus width would be a lurch across the screen.

## Reference material

- **The design review:** `../mancia-design-review.html` — open the ribbon tab.
  It carries the state inventory, the supporting dialogs, the color-discipline
  swatches, and the two placement mockups this plan implements.
- **The critique snapshot:** `../../.impeccable/critique/` — the two dated
  markdown files hold the heuristic scoring and priority findings for the app
  and for the review document itself. The P1/P2 findings referenced throughout
  this plan come from the first one.
- **Existing architecture:** `../ARCHITECTURE.md` (component map, core flow,
  provider protocol, permissions) and `../SPEC.md` (repository layout, build,
  debug hooks). Both need updating at stage 11.
