# Mancia landing page UI contract

The landing page is a distilled warm technical folio grounded in the shipping app palette and real product screenshot.

## Direction

- Surface mode: persuade, with developer-tool restraint.
- Visual ground: `Sources/Mancia/Panel/Palette.swift`, `Sources/Mancia/Ribbon/RibbonPalette.swift`, and `docs/assets/mancia-ribbon.png`.
- Variance: 6 of 10. Editorial confidence without decorative illustration.
- Motion: 2 of 10. Only control feedback moves.
- Density: 6 of 10. Product proof and technical distinctions remain visible without setup prose.

## Tokens

- The semantic token layer in `styles.css` owns background, foreground, card, primary, secondary, muted, border, ring, and radius values.
- Mancia vermilion is the only brand accent.
- All spacing uses the shared `--space-*` scale.
- Interactive targets meet `--target`; focus uses `--ring`.

## Theme

- Appearance follows `prefers-color-scheme` automatically.
- There is no theme selector, query override, or stored preference.

## Structure

1. Compact hero with positioning and three distinct CTA intents.
2. Real product proof plus the five-action use-case ledger.
3. One prose comparison, four distinctive capabilities, and the provider boundary.
4. Minimal license footer.

## Invariants

- No top navigation bar.
- Every CTA intent appears once: download, repository, documentation.
- The repository's real screenshot is the only product demonstration.
- Do not rebuild the ribbon in HTML or invent generated output.
- Installation details live in the repository README.
- Headings carry hierarchy without eyebrows, section numbers, or metric badges.
- Body copy uses the platform sans to align with the macOS utility; monospace is limited to shortcuts.
- Reduced Motion removes nonessential transitions.
- Forced Colors preserves visible borders around major controls and the proof surface.
