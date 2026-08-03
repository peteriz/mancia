# Tight non-Custom ribbon with status in Run

## Screenshot finding

The 760pt non-Custom width reserves room for three separate trailing elements: version/Cancel, a standalone status label, and Run. In the applied state this leaves visible slack between Custom and the trailing cluster. The standalone `Improved` status also duplicates state that the primary button can communicate.

## Plan

1. Consolidate status into the primary button.
   - Remove `inlineStatus` from the trailing cluster.
   - Show `Working…` in the disabled Run button while a request is running.
   - Show `✓ Improved` in the button after an edit lands.
   - On hover in the applied state, reveal `Run again ↵` so the existing rerun behavior remains clear.
   - Keep VoiceOver phase announcements unchanged, including the more specific action progress label.

2. Keep only the necessary secondary control beside the button.
   - Running: Cancel + status button.
   - Applied with history: version navigation + status button.
   - Idle/error: Run only.

3. Tighten the fixed non-Custom width.
   - Reduce `RibbonPlacement.standardWidth` from 760pt to the smallest fixed width that fits the widest consolidated non-Custom state, targeting about 700pt.
   - Keep that exact width across idle, running, confirm, applied, and error states.
   - Keep Custom as the only state that expands to 900pt.

4. Preserve behavior and accessibility.
   - Do not change action execution, Cancel, version navigation, Return, or Command-number shortcuts.
   - Update the Run button's accessibility value/help to describe its current phase and rerun behavior.
   - Respect Reduce Motion for the applied hover-label transition.

5. Verify the result.
   - Add focused tests for phase-to-button-label mapping and the fixed standard width.
   - Run `make build`, `make test`, and `make shot`.
   - Render idle, running, and applied states at the same width and inspect for clipping or dead space.
   - Update architecture/spec wording that still describes a separate status label or the 760pt width.

## Acceptance criteria

- No standalone `Improved` or running status appears beside the primary button.
- The primary button communicates Working, Improved, and rerun states.
- The non-Custom bar is visibly tighter and never resizes between phases.
- Only selecting Custom expands the bar.

## Assumption for approval

The applied button will read `✓ Improved` and switch to `Run again ↵` on hover; clicking or pressing Return keeps the existing rerun behavior.
