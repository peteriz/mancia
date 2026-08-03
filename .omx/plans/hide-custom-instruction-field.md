# Hide the custom-instruction field by default

## Requirements summary

- Keep the existing ribbon controls as the default interface and omit the instruction `TextField` from the default view hierarchy.
- Rename the user-facing action from `Your instruction` to `Custom instruction` (sentence/title casing consistent with the other action labels).
- Selecting `Custom instruction` explicitly reveals and focuses the field.
- Command-1/2/3 execute the three specialized built-in actions immediately; they do not merely select an action and wait for Return/Run.
- Command-4 selects `Custom instruction`, reveals the field, and focuses it; it does not execute until the user supplies an instruction.
- Reveal the field with a fast, smooth, left-anchored horizontal grow inside the ribbon's existing fixed width.
- Respect Reduce Motion while retaining a short, non-spatial disclosure cue.
- Do not change the ribbon placement contract or grow the AppKit window horizontally.

## Current-state findings

- `RibbonView.commandRow` always renders Target, Action, Direction, and Run; the direction field is a `TextField` with a 140...460 pt width (`Sources/Mancia/Ribbon/RibbonView.swift:123-145`, `284-305`).
- Action selection is implicit: no pinned preset plus an empty field means Improve, while typing changes the resolved action to `Your instruction` (`Sources/Mancia/Panel/PanelModel.swift:38-42`, `180-215`). There is no state for selecting an empty custom action.
- Initial focus, menu focus hand-back, and the Tab ring all assume Direction always exists (`Sources/Mancia/Panel/PanelModel.swift:66-76`, `91-109`, `128-177`; `Sources/Mancia/Ribbon/RibbonView.swift:71-80`, `641-658`).
- The ribbon width is imposed by placement at 600...900 pt and only height is content-measured, so the field should grow inside the row while the existing spacer absorbs the layout change (`Sources/Mancia/Ribbon/RibbonPlacement.swift:144-160`; `Sources/Mancia/Ribbon/RibbonWindow.swift:223-271`).
- Existing UI motion is short (0.12...0.22 s) and already observes Reduce Motion (`Sources/Mancia/Ribbon/RibbonWindow.swift:49-58`, `128-140`, `181-211`).

## Acceptance criteria

1. A fresh ribbon session resolves to Improve and contains no visible or focusable instruction field.
2. The Action menu and resolved Action label say `Custom instruction`; no runtime UI or accessibility value says `Your instruction`.
3. Selecting Custom instruction, including with Command-4, makes the field visible and moves keyboard focus into it without starting a request.
4. The field appears in roughly 0.15-0.18 seconds using a left-anchored horizontal grow; the ribbon window width and horizontal placement do not change.
5. With Reduce Motion enabled, disclosure avoids horizontal scaling and uses an immediate or short fade.
6. Direction participates in Tab order only while visible; the default state leaves Target (when interactive), Action, and Run as the focus stops.
7. Command-1/2/3 each start their mapped built-in action immediately, exactly once, without requiring Return or a click on Run.
8. Improve and named presets never consume instruction text that is hidden from the user.
9. Existing target selection, running/error/confirmation states, and Return/Run routing continue to work.

## Implementation steps

1. **Make action choice explicit in the model.** In `Sources/Mancia/Panel/PanelModel.swift`, represent the default/preset/custom choice directly rather than deriving custom mode from whether text happens to be present. Add one source of truth for field visibility, resolve the title/symbol from that choice, reset fresh sessions to Improve, and route Custom to `.custom(trimmedText)`. Replace the old `clearPreset` semantics with an explicit custom-selection operation.

2. **Update keyboard and focus routing for a conditional field.** In `Sources/Mancia/Panel/PanelKeyCommand.swift`, `Sources/Mancia/Panel/KeyablePanel.swift`, and `Sources/Mancia/Ribbon/RibbonWindow.swift`, change Command-1/2/3 from selection-only commands into immediate action commands that call the mapped built-in action once without waiting for Return/Run. Make Command-4 select Custom instruction, reveal the field, and focus it without executing; retire the old Command-0 unpin shortcut. In `PanelModel`/`RibbonView`, omit Direction from the default Tab order, focus Run (the default primary action) when the field is hidden, and focus Direction only after Custom has inserted it. Mouse menu choices can continue to select an action and hand focus to the appropriate primary control.

3. **Conditionally render and animate the field.** In `Sources/Mancia/Ribbon/RibbonView.swift`, render `directionCell` only for the custom choice. Add a private horizontal-reveal transition that clips/scales on the x-axis from the leading edge and combines with a light opacity change, using a fast animation consistent with the existing 0.18-second resize timing. Use a fade/no spatial transform under Reduce Motion. Trigger relayout when the selected action changes so hiding a wrapped field also restores the row height smoothly.

4. **Keep execution behavior honest.** Give the immediate Command-1/2/3 path the same lock/capture handling as Run, so a shortcut pressed during background selection capture queues exactly one action and shortcuts remain inert during running/confirmation. Ensure Run remains enabled for Improve/presets, while an explicitly selected Custom action cannot silently fall back to Improve when its field is blank. Ensure hidden custom draft text is not passed as preset guidance. Preserve or clear the draft according to the approved product decisions below, and reset/hide after a successful run only if approved.

5. **Update focused tests and current documentation.** In `Tests/ManciaTests/ManciaTests.swift`, replace implicit typing-based action tests with coverage for fresh default state, custom selection/title, blank-custom behavior, dynamic Tab order, focus after custom/preset choices, shortcut locking, immediate Command-1/2/3 execution (including exactly-once and capture/locked-state behavior), Command-4 disclosure without execution, switching actions with a draft, and reset behavior. Update `Sources/Mancia/DocsShot.swift` so the generated custom-state example explicitly selects Custom, regenerate `docs/assets/mancia-ribbon.png`, and align `README.md`, `docs/SPEC.md`, and `docs/ARCHITECTURE.md` with the disclosed-field interaction and shortcut table.

6. **Verify.** Run `make test` and `make build`; regenerate the documentation shot with `make shot` and inspect it. Manually verify fresh/default, Custom reveal, preset switching, immediate Command-1/2/3 execution without Return, Command-4 disclosure without execution, Tab/Shift-Tab, Return/Run, a wrapped multi-line field, narrow and wide host windows, and Reduce Motion. Confirm the field grows inside the lane without changing the lane's width or horizontal anchor.

## Risks and mitigations

- **Hidden text affects a visible preset:** route preset actions independently of the custom draft and test the switch explicitly.
- **A shortcut selects and then accidentally runs through a second route:** give Command-1/2/3 one direct dispatch path and assert one provider invocation per keypress.
- **Focus points to a removed view:** derive focusable cells and focus hand-back from field visibility; defer focus until the inserted field exists, following the current `adopt` pattern.
- **The effect looks like zoom rather than horizontal growth:** animate only x-scale/clip from the leading edge, keep y-scale at 1, and visually inspect at 600 and 900 pt.
- **Removal of a multi-line field leaves stale window height:** observe action-choice changes and reuse `RibbonWindow.reposition()`/off-screen height measurement.
- **Accessibility regression:** retain `CustomInstruction`, Action, and Run identifiers/labels, keep the renamed title feeding accessibility values, and provide a Reduce Motion path.

## Open product decisions

1. **Three-action mapping (confirmation needed):** The current menu contains Improve, Sharpen, Plan first, and Tighten (`Sources/Mancia/Panel/PanelPreset.swift:19-29`). Recommended interpretation: Command-1 = Sharpen, Command-2 = Plan first, Command-3 = Tighten; Improve remains the default Run/Return action.
2. **Interface scope:** Recommended: keep the existing Action menu plus Run control; “buttons/labels” means the current ribbon controls with the field absent. Showing all actions as simultaneous buttons is a larger layout redesign and does not fit the stated field-disclosure scope cleanly at the 600 pt minimum.
3. **Blank Custom:** Recommended: disable/inhibit Run until the custom field contains non-whitespace text, rather than unexpectedly running Improve or starting a request that ends in validation failure.
4. **Switching away from Custom:** Recommended: hide the field, preserve its draft for switching back during the same session, and never use the hidden draft as preset guidance.
5. **After a successful custom run:** Recommended: return to Improve and the buttons-only state, matching today's behavior where clearing the text resolves the next action back to Improve.

## Approval gate

No implementation starts until the user approves this plan and resolves or accepts the recommended open decisions.
