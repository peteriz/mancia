# Menu-Bar Command Ribbon — implementation package

This directory is the complete brief for replacing Mancia's floating edit panel
with the **Menu-Bar Command Ribbon**: a slim command lane that opens in one
predictable place instead of next to the caret.

The direction was chosen in the frontend design review
(`../mancia-design-review.html`, revision 2) over the Proofing Rail, after the
Inline Selection Lens was rejected. Read the review's ribbon tab for the visual
intent; read the documents here for what to build.

## Read in this order

| # | Document | What it settles |
|---|----------|-----------------|
| 1 | [01-behavior-spec.md](01-behavior-spec.md) | What the ribbon is, its states, keyboard model, action routing, and copy |
| 2 | [02-placement.md](02-placement.md) | The hybrid placement rule, as a pure testable function, with every edge case |
| 3 | [03-visual-spec.md](03-visual-spec.md) | Geometry, palette tokens (including three contrast fixes), motion |
| 4 | [04-build-plan.md](04-build-plan.md) | Eleven staged commits, each with files, changes, and acceptance criteria |
| 5 | [05-test-plan.md](05-test-plan.md) | Unit tests to add and the manual matrix that unit tests cannot cover |
| 6 | [06-decisions-and-open-questions.md](06-decisions-and-open-questions.md) | What is settled and why; the five questions still open, with recommendations |

## What is being replaced, and what is not

**Replaced:** the presentation layer only — `Sources/Mancia/Panel/EditPanel.swift`
(the `NSPanel` and its `.near` / `.nearMouse` / `.centered` placement) and
`Sources/Mancia/Panel/EditPanelView.swift` (the SwiftUI command row).

**Kept, unchanged:** `EditCoordinator`, `PanelModel`, `SelectionCapture`,
`ApplyConfirmation`, `PromptGuard`, `Actions.swift`, the whole `Providers/`
layer, and the pasteboard-snapshot + synthetic-keystroke apply mechanism. The
ribbon is a new way to *drive* the existing session machine, not a new session
machine. If you find yourself editing `EditCoordinator`'s apply or version
logic, stop and re-read this paragraph — the exceptions are enumerated
explicitly in stage 6 and stage 7 of the build plan and nowhere else.

## Guardrails

These come from `CLAUDE.md` and the existing code. They are not negotiable
without asking the user first.

- **Swift 6 strict concurrency.** No `@unchecked Sendable` to paper over a
  race. UI, hotkey, pasteboard and Accessibility work stays `@MainActor`.
- **One primary type per file**, kept small, in the existing folder layout
  (`Panel/`, `Providers/`, `Settings/`). New ribbon files live in
  `Sources/Mancia/Ribbon/`.
- **Testable logic is pure and static.** Placement math and phase→layout
  decisions must be free functions or static helpers taking injected values, in
  the style of `CopilotCLIProvider` and `PromptBuilder`. Anything requiring a
  live `NSScreen` is a thin adapter over a pure core.
- **No new dependencies.** The app already has `KeyboardShortcuts`; that is the
  whole third-party surface and it stays that way.
- **Accessibility, pasteboard and synthetic keystrokes are hard to unit-test.**
  Any change touching them must document what was manually tested, in the
  commit body. Stage 2 is the only stage that adds Accessibility calls.
- **The provider layer is an extension point.** Copilot is today's only
  provider but not a permanent one — no ribbon copy or settings label may name
  Copilot where a neutral word ("the provider", "the model") works. The
  readiness checklist in stage 8 is the one place a provider name is allowed,
  because it reports on a specific configured provider.

## Definition of done

1. `make build` and `make test` pass, with the new tests from
   [05-test-plan.md](05-test-plan.md) added to `Tests/ManciaTests/`.
2. The manual matrix in 05 has been walked and its results recorded.
3. `EditPanel.swift` and `EditPanelView.swift` are deleted (stage 11), with no
   dangling references and no dead `Placement` enum.
4. `docs/ARCHITECTURE.md` and `docs/SPEC.md` are updated: the component map,
   the core flow, and the panel sections all describe the ribbon.
5. Accessibility permission still works from a cold grant, and the app still
   edits text inline in a non-Cocoa host (test in a browser textarea).

## Scope boundaries

Explicitly **out of scope** for this work, recorded so they are not
accidentally absorbed:

- The Proofing Rail as a full mode. Only its review gate is borrowed (stage 6).
- A word-level or character-level diff in the review gate. v1 shows the size
  delta plus a collapsible full-result preview; a real diff is a follow-up.
- New presets. `PanelPreset.all` stays `[.improve]`; the ribbon just makes the
  default visible. Adding presets is a separate, easy change afterward.
- Any provider, prompt, or apply-strategy change.
