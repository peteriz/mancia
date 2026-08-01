# 03 — Visual specification

> **Superseded in part.** The lane shipped, then a design review of the
> running app removed the per-cell captions ("Target", "Action",
> "Direction") and folded status and iteration in beside Run. The row is one
> line, not two; each control names itself with an icon and its own value.
> See `docs/ARCHITECTURE.md` and `docs/SPEC.md` for what the lane does today.
> Everything else here — the cells, the states, the keyboard model and the
> copy — still holds. The lane's maximum width is 900pt, not the 1200pt Q1
> settled on.

The ribbon keeps Mancia's identity exactly: cream and ink surfaces, one
vermilion action, green and warm red reserved for status. Every value below
comes from `Sources/Mancia/Panel/Palette.swift`, with three contrast
corrections specified in this document.

## Register

The lane runs the palette's **dark register** — the same ink surface and
`#FF6A4D` accent the panel already uses in dark appearance — regardless of the
system appearance. Rationale: the lane sits against the menu bar, which is dark
on most configurations, and a cream bar hanging under a dark menu bar reads as
a detached foreign object. The review region and any popovers stay in the
active appearance's register, because they are content surfaces, not chrome.

This is a deliberate departure from `Palette`'s dynamic light/dark behavior for
this one surface. Implement it by referencing the dark values explicitly rather
than by defeating the dynamic colors:

```swift
// Sources/Mancia/Ribbon/RibbonPalette.swift
/// The lane's fixed dark register. The ribbon reads as chrome adjoining the
/// menu bar, so it does not follow system appearance the way `Palette` does.
/// Values mirror `Palette`'s dark column so the two surfaces stay one system.
enum RibbonPalette {
    static let lane        = Color(hex: 0x211C16)  // Palette.raised, dark
    static let laneEdge    = Color(hex: 0x352E24)  // Palette.border, dark
    static let text        = Color(hex: 0xF3ECDE)  // Palette.text, dark
    static let caption     = Color(hex: 0x9E9483)  // Palette.textSecondary, dark
    static let action      = Color(hex: 0xFF6A4D)  // Palette.accent, dark
    static let onAction    = Color(hex: 0x25120C)  // Palette.onAccent, dark
    static let applied     = Color(hex: 0x5BC57C)  // Palette.applied, dark
    static let error       = Color(hex: 0xF0917A)  // Palette.error, dark
}
```

`Palette` currently has no public hex initializer — its `nsColor(_:)` is
private. Add a small `Color(hex:)` helper *in `Palette.swift`*, internal, and
have both types use it. Do not duplicate the conversion.

Verified contrast in this register, against the lane `#211C16`:

| Pair | Ratio | Requirement |
|---|---|---|
| `text` on lane | 14.38:1 | ≥4.5 body |
| `caption` on lane | 5.65:1 | ≥4.5 body |
| `onAction` on `action` | 6.34:1 | ≥4.5 body |
| `applied` on lane | 7.83:1 | ≥4.5 body |
| `error` on lane | 7.27:1 | ≥4.5 body |
| `action` on lane | 5.97:1 | ≥3 non-text |

## Three contrast fixes to `Palette.swift`

These are the P2 finding from the design review, and they apply to the whole
app, not just the ribbon. Ship them as stage 1, separately, so a regression is
attributable.

| Token | Now | Change to | Was | Becomes | Why |
|---|---|---|---|---|---|
| `accent` light | `0xD8513A` | `0xC2412C` | 4.07:1 | **5.14:1** | White text on the run button fails AA today |
| `textSecondary` light | `0x857866` | `0x6E6250` | 3.76:1 | **5.20:1** | Every caption and status line fails AA today |
| `textFaint` light | `0xA2957F` | `0x756850` | 2.57:1 | **4.76:1** | Placeholder text fails badly; placeholders need 4.5:1 |

All measured against the light surface `#F5EFE3`. The dark column already
passes (`textSecondary` 6.18:1, `textFaint` 4.72:1) and must not be touched.

One more, lower confidence, flagged rather than prescribed: `applied` light
`0x3E9E57` is 2.94:1, which fails even the 3:1 non-text threshold for the
status dot. `0x2F7A44` gives 4.60:1. Apply it if the green still reads as
"success" to you at 7pt; ask if unsure.

## Geometry

All values in points.

### Command row

| Property | Value |
|---|---|
| Row height | 56 |
| Horizontal padding | 16 leading, 12 trailing |
| Cell gap | 1 (a hairline divider, `laneEdge`, full row height) |
| Target cell width | 150, fixed |
| Action cell width | 170, fixed |
| Direction cell | fills remaining space, min 220 |
| Run control | intrinsic, min width 84, height 32, corner radius 8 |
| Caption | 10pt semibold, `caption`, tracking +0.04em, uppercase off |
| Value | 13pt medium, `text` |
| Caption → value gap | 2 |

Cell dividers stop 10pt short of the row's top and bottom edges — a full-bleed
divider makes the lane read as a table rather than a sentence.

### Status strip

| Property | Value |
|---|---|
| Height | 34 |
| Top border | 1pt `laneEdge` |
| Horizontal padding | 16 |
| Status dot | 7 diameter, phase-colored |
| Label | 11.5pt medium |
| Trailing controls | ghost buttons, 11pt semibold, 26 tall |

### Review region

| Property | Value |
|---|---|
| Padding | 16 |
| Heading | 15pt semibold, `text` |
| Delta | 11.5pt medium, `caption` |
| Preview | 12pt, monospaced, max height 220, scrollable, 1pt `laneEdge` border, radius 8 |
| Button row | right-aligned, 8 gap, 30 tall |

Monospaced is correct here specifically because the preview is a verbatim
result being inspected character-for-character against a character delta —
this is the one place in the app where it is not costume.

### Corners and shadow

Driven by `RibbonPlacement.Anchor`:

| Anchor | Corners | Shadow |
|---|---|---|
| `.screen` | top 0, bottom 12 — the lane hangs from the screen edge | `y: 8, blur: 20, black 28%` |
| `.hostWindow` | all 12 — the lane floats over the host | `y: 10, blur: 26, black 34%` |

Both shadows carry a real vertical offset; a zero-offset halo is decoration.

## Motion

One authored moment: the lane arrives.

- **Entrance:** translate from `-height` to `0` with opacity 0→1,
  220ms, `easeOut` (exponential feel — `.timingCurve(0.16, 1, 0.3, 1)`).
  The lane slides down from behind the menu bar, which is where it lives.
- **Exit:** reverse, 140ms. Faster out than in.
- **Height changes** (status strip appearing, review region opening): animate
  the window frame, 180ms, same curve. Anchored at the top edge so the lane
  grows downward — see the re-resolve note in
  [02-placement.md](02-placement.md).
- **Running:** the existing `SwooshBorder` comet
  (`EditPanelView.swift:443`) moves from the field to the **Run control's**
  border. It is the same component; retarget it, do not rewrite it.
- **Phase cross-fades:** 200ms `easeInOut`, matching the current panel.

Reduce Motion (`@Environment(\.accessibilityReduceMotion)`, already observed in
`EditPanelView.swift:21`) replaces the entrance translate with a plain
120ms opacity fade, and the comet with the still accent ring the current panel
already falls back to.

## Color discipline

The rule the design review holds both directions to, restated as an
implementation constraint:

- **Vermilion appears exactly once per surface.** On the command row that is
  `Run`. In the review region that is `Replace ↵`. Nowhere else — not on the
  Target or Action menus, not on hover, not on focus rings, not on the status
  dot in `.idle`.
- **Green means applied. Warm red means error.** No other element gets a hue.
- **Focus** is carried by a firmer neutral edge, not the accent — the existing
  `fieldStroke` rationale at `EditPanelView.swift:166` applies unchanged and is
  the reason the accent still means something.

A visible focus ring is nonetheless required on every focusable cell for
keyboard users; use `text.opacity(0.35)` at 2pt, which is the neutral treatment
the panel already uses, not the system accent.

## Accessibility

- Every cell gets an `accessibilityLabel` and a stable
  `accessibilityIdentifier`; keep the existing identifiers where the control
  survives (`CustomInstruction`, `Run`, `Cancel`, `ReplaceDocument`,
  `IterBack`, `IterCounter`, `IterForward`, `Scope`) so any external harness
  keeps working, and add `Target`, `Action`, `ShowResult`, `KeepEditing`,
  `ErrorDetails`, `CopyError`, `Retry`.
- The status strip is an `accessibilityLiveRegion` equivalent: post an
  announcement on phase change so VoiceOver users hear `Running`, `Improved`,
  and errors without polling. `NSAccessibility.post(element:notification:)`
  with `.announcementRequested`.
- Never convey state by the dot color alone — the label beside it always names
  the state in words. This is already true today and must stay true.
- Minimum hit target 28×28 for every control in the lane; the Run control at
  84×32 and ghost buttons at 26 tall need a `contentShape` expansion to reach
  it.
