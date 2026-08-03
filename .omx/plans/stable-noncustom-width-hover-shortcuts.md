# Stable non-Custom width and hover shortcuts

## Goal

Keep the ribbon at one stable size through every non-Custom state, while making each action's Command-number shortcut immediately visible on hover. Selecting Custom remains the only interaction that expands the ribbon to reveal the text field.

## Current behavior and constraints

- `PanelModel.prefersExpandedRibbon` currently returns true for Custom, running, and applied states, so execution can resize the panel even when Custom is not selected.
- `RibbonWindow` converts that preference into the 600pt compact or 900pt expanded placement width.
- The current 600pt row clips the running/applied controls once Cancel, status, and version controls are present.
- Each button already has a delayed system help tooltip containing its shortcut, but there is no immediate hover treatment.
- Button geometry must remain tight, and hovering must not resize a button or the panel.

## Recommended design

1. Introduce one fixed standard non-Custom ribbon width.
   - Measure the widest existing non-Custom state (running/applied) and choose the smallest width that contains it cleanly; current layout suggests roughly 760pt.
   - Use this same standard width for idle, capturing, running, confirmation, applied, and error states.
   - Keep the current 900pt expanded width for Custom.

2. Make Custom the sole expansion trigger.
   - Replace or narrow `prefersExpandedRibbon` so it depends only on `isCustomInstructionSelected`.
   - Have `RibbonWindow` request the standard width for every other state.
   - Preserve the existing fast horizontal Custom expansion and collapse animation.

3. Show shortcuts immediately on hover without changing layout.
   - Track the hovered action locally in `RibbonView`.
   - Render the title and `⌘1`…`⌘5` in the same fixed label footprint, showing the title normally and the shortcut while hovered.
   - Use a short fade (about 0.1 seconds), disabled when Reduce Motion is enabled.
   - Retain the full action name in accessibility metadata and system help.

4. Update focused tests and documentation.
   - Test that running/applied states no longer request expansion.
   - Test that Custom alone requests the 900pt layout.
   - Test the shortcut-label mapping for all five actions.
   - Update width terminology or screenshots only where the changed standard width makes existing material inaccurate.

5. Verify the complete interaction.
   - Run `make build`, `make test`, and `make shot`.
   - Visually check idle, running, applied, and error states at the same width.
   - Manually check that hovering each button reveals the correct shortcut without moving any neighboring control.
   - Check that selecting Custom still moves it left, expands the bar, and focuses the text field.

## Acceptance criteria

- The panel width is invariant across every non-Custom state.
- Only Custom expands the panel and reveals the text field.
- Hovering each action immediately shows its correct `⌘N` shortcut.
- Hovering does not change button or panel geometry.
- All five Command-number shortcuts continue to behave as specified.

## Open decision

- Recommended: allow the fixed non-Custom width to increase from 600pt to the smallest measured width that fits every state (expected around 760pt). Keeping exactly 600pt would instead require a more invasive redesign of the running/applied controls.
