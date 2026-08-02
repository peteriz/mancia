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
