# Render all actions as compact buttons

## Requirements summary

- Replace the single Action menu with five simultaneously visible buttons: Improve, Sharpen, Plan first, Tighten, and Custom.
- Map Command-1 through Command-5 to those buttons in that visual order.
- Preserve the established direct-action behavior: Improve/Sharpen/Plan first/Tighten execute immediately from either their button or shortcut; Custom selects and focuses its field without executing.
- Rename `Custom instruction` to `Custom` everywhere in the current runtime UI and documentation.
- Keep the default ribbon compact, with no text field.
- When Custom is selected, move Custom to the leading edge of the action group, insert the text field immediately after it, keep the built-ins visible, and animate the whole ribbon from its compact width toward its expanded width.

## Current-state findings

- `RibbonView.commandRow` currently renders one fixed-width Action `Menu`, conditionally inserts `directionCell`, and fills an externally imposed 600...900 pt ribbon width (`Sources/Mancia/Ribbon/RibbonView.swift:115-152`, `235-322`).
- `PanelModel.ActionChoice` already distinguishes a preset from Custom and correctly prevents blank Custom from executing, but keyboard actions currently cover only the three specialized presets (`Sources/Mancia/Panel/PanelModel.swift:18-20`, `128-151`, `195-233`).
- Command-1/2/3 currently run Sharpen/Plan first/Tighten and Command-4 selects Custom; Command-5 is unused (`Sources/Mancia/Panel/PanelKeyCommand.swift:18-23`, `49-53`).
- Focus currently treats the whole Action menu as one cell. Five visible buttons need stable per-button focus identities if Tab and focus rings are to remain honest (`Sources/Mancia/Panel/PanelModel.swift:16-17`, `168-187`; `Sources/Mancia/Ribbon/RibbonView.swift:274-280`).
- `RibbonPlacement` currently derives width only from host geometry, using a 600 pt minimum and 900 pt maximum; `RibbonWindow.reposition()` already animates frame changes in 0.18 seconds (`Sources/Mancia/Ribbon/RibbonPlacement.swift:144-160`, `194-215`; `Sources/Mancia/Ribbon/RibbonWindow.swift:122-140`, `223-271`).

## Acceptance criteria

1. A fresh ribbon shows five separate action buttons in this order: Improve, Sharpen, Plan first, Tighten, Custom; the text field is absent.
2. The five buttons use compact chrome: 32 pt control height, approximately 8 pt horizontal label padding, and 4 pt spacing inside the action group, while retaining clear hit targets and selected/focus states.
3. Clicking Improve, Sharpen, Plan first, or Tighten starts that action immediately and exactly once.
4. Command-1/2/3/4 starts Improve/Sharpen/Plan first/Tighten respectively, immediately and exactly once; Command-5 selects Custom without starting a request.
5. Selecting Custom changes the action layout to Custom, text field, Improve, Sharpen, Plan first, Tighten, with all five buttons still visible.
6. Custom mode focuses the text field, disables Run while the field is blank, and submits the trimmed instruction through Return or Run.
7. On a host with enough room, the ribbon animates from its compact 600 pt width toward its expanded 900 pt width in about 0.18 seconds while staying centered on the same host/selection anchor. Width remains clamped safely on narrower screens.
8. The Custom button and field insertion use the same fast horizontal transaction; Reduce Motion avoids spatial movement and applies the final frame without the width/reordering animation.
9. Tab/Shift-Tab can reach each visible action button, skips the absent field by default, and includes the field only in Custom mode.
10. Running/confirmation locks all five buttons and all Command-number shortcuts; successful completion restores the compact Improve-default state.
11. No current runtime UI, accessibility label, README, specification, or architecture text refers to `Custom instruction`.

## Implementation steps

1. **Unify the five action choices and keyboard mapping.** In `Sources/Mancia/Panel/PanelPreset.swift` and `Sources/Mancia/Panel/PanelModel.swift`, expose the four presets plus Custom as one ordered UI/shortcut catalog while retaining `ActionChoice` as the execution source of truth. Generalize the direct shortcut entry point so indices 0...3 run the four built-ins and index 4 selects Custom. Keep lock, blank-Custom, draft-preservation, and post-success reset behavior explicit.

2. **Replace the Action menu with compact buttons.** In `Sources/Mancia/Ribbon/RibbonView.swift`, remove `actionCell`/menu shortcut hints and build a tight, stable-identity action-button strip. Give selected, hover, disabled, focus, and accessibility states clear styling using the existing ribbon palette. Use visual order Improve/Sharpen/Plan first/Tighten/Custom by default; in Custom mode reorder to Custom/text field/the four built-ins without hiding any button.

3. **Make focus match the five visible controls.** In `Sources/Mancia/Panel/PanelModel.swift` and `Sources/Mancia/Ribbon/RibbonView.swift`, replace the single `.action` focus stop with per-action stops (for example `.action(index)`), generate Tab order from the current visual order, and continue inserting `.direction` only while Custom is active. Keep keyboard shortcuts independent of the current focus stop.

4. **Remap Command-1 through Command-5.** In `Sources/Mancia/Panel/PanelKeyCommand.swift`, `Sources/Mancia/Panel/KeyablePanel.swift`, and `Sources/Mancia/Ribbon/RibbonWindow.swift`, map 1...4 to immediate built-in execution and 5 to Custom selection/focus. Route mouse clicks and number shortcuts through the same model operations so both paths execute exactly once and honor capture/lock state.

5. **Add compact and expanded ribbon widths.** Extend `RibbonPlacement.Context` with a preferred width (defaulting to the current maximum for compatibility), clamp it to the existing 600...900 pt safe range, and have `RibbonWindow.currentContext()` request 600 pt normally and 900 pt for Custom (`Sources/Mancia/Ribbon/RibbonPlacement.swift:144-160`, `177-215`; `Sources/Mancia/Ribbon/RibbonWindow.swift:228-284`). Reuse `reposition()` for the 0.18-second centered AppKit frame animation and the existing field transition for insertion; disable spatial resize/reordering under Reduce Motion.

6. **Update tests and current documentation.** In `Tests/ManciaTests/ManciaTests.swift`, cover the 1...5 mapping, exact-once execution for 1...4, Custom disclosure for 5, locked behavior, ordered per-button focus, layout order, preferred-width clamping, compact-to-expanded width selection, and reset. Update `Sources/Mancia/DocsShot.swift`, regenerate `docs/assets/mancia-ribbon.png`, and align `README.md`, `docs/SPEC.md`, and `docs/ARCHITECTURE.md` with the five visible buttons and new shortcuts.

7. **Verify.** Run `make build`, `make test`, and `make shot`. Visually inspect default and Custom states at 600 and 900 pt, then manually check clicking all buttons, Command-1...5, Tab/Shift-Tab, Return/Run for Custom, locked phases, narrow hosts, field wrapping, and Reduce Motion.

## Risks and mitigations

- **Five buttons overflow the compact width:** remove menu-only icon/chevron chrome, keep 4 pt action spacing and compact horizontal padding, and verify the 600 pt layout at the longest labels.
- **A click and key equivalent both dispatch:** expose one model entry point per action and assert exactly one `onPerform` call for each path.
- **Reordering loses focus or produces duplicate views:** give buttons stable IDs, derive focus order from visual order, and move focus into Direction only after Custom is selected.
- **The window resize fights SwiftUI layout:** let `RibbonWindow.reposition()` own the AppKit frame and use the view animation only for internal reordering/field insertion.
- **Expansion shifts the ribbon away from the edited text:** preserve the established anchor and center the new width on the same host, with existing screen clamping.
- **Narrow screens cannot visibly expand:** clamp safely; Custom still inserts a usable minimum-width field even when the host cannot provide the full 900 pt target.

## Open question

- Recommended Custom layout: keep every action visible and reorder to `Custom → text field → Improve → Sharpen → Plan first → Tighten`. If “move it to the left” instead means hide the four built-ins while Custom is active, the view and focus plan should be simplified accordingly.

## Approval gate

No application-code changes start until the user approves this plan and confirms or corrects the Custom-mode layout interpretation.
