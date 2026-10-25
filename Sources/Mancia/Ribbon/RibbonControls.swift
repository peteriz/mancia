import SwiftUI

/// Small controls shared by the ribbon's command row, status strip and
/// scope-approval gate.
///
/// These began as private helpers inside the floating panel's view. When the
/// ribbon replaced it they moved here as internal types with their colors
/// injected, so a control used in more than one register has one definition
/// rather than a copy to keep in sync.

/// A quiet text button for a status row: no outline at rest, a soft fill on
/// hover, so a row of three recoveries reads as words rather than as boxes.
struct GhostButton: View {
    let title: String
    var tint: Color
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, tint: Color = RibbonPalette.caption, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                // The label is 15pt tall; the spec's 28pt minimum hit target is
                // reached by the shape, not by the ink.
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(RibbonPalette.controlHover.opacity(hovered ? 1 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }
}

/// A small filled button for the one decisive action in a gate — today,
/// approving a whole-document request.
struct AccentButton: View {
    let title: String
    var fill: Color
    var foreground: Color
    let action: () -> Void
    @State private var hovered = false

    init(
        _ title: String,
        fill: Color = RibbonPalette.accent,
        foreground: Color = RibbonPalette.onAccent,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.fill = fill
        self.foreground = foreground
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(hovered ? 0.12 : 0)))
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }
}

/// The working signal: a beam of light sweeping round the control's border.
///
/// A conic gradient — clear for most of the turn, rising to `tint` and fading
/// out again — rotated about the control's center and drawn only in its
/// border. Because the sweep is angular, the light races along the short ends
/// of a wide button and slows along its long sides, which is what gives it
/// its pull. Driven by `TimelineView(.animation)` off the wall clock, so the
/// rate holds steady whatever else the lane is animating. Reduce Motion
/// replaces it with a steady lit border.
struct SwooshBorder<S: InsettableShape>: View {
    var shape: S
    var tint: Color
    var animated: Bool
    var lineWidth: CGFloat = 1.5

    /// One lap, in seconds.
    private let period: Double = 1.3

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let lap = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period
                    shape.strokeBorder(beam(at: lap * 360), lineWidth: lineWidth)
                }
            } else {
                shape.strokeBorder(tint, lineWidth: lineWidth)
            }
        }
        .allowsHitTesting(false)
    }

    /// Clear for the first 62% of the turn, brightest at 82%, clear again by
    /// the end — so the beam has a long tail behind a sharp leading edge.
    private func beam(at degrees: Double) -> AngularGradient {
        AngularGradient(
            stops: [
                .init(color: tint.opacity(0), location: 0),
                .init(color: tint.opacity(0), location: 0.62),
                .init(color: tint, location: 0.82),
                .init(color: tint.opacity(0), location: 1),
            ],
            center: .center,
            startAngle: .degrees(degrees - 90),
            endAngle: .degrees(degrees + 270))
    }
}

// MARK: - Focus ring

extension View {
    /// The lane's focus ring.
    ///
    /// A soft neutral edge, never the accent: vermilion marks the action in
    /// play, and spending it on focus would empty it of meaning. Drawn
    /// outside the control so it never reflows the cell it belongs to.
    ///
    /// The system effect is switched off with it — left on, AppKit draws its
    /// blue ring over the top, which is the system accent by another name and
    /// reads as a second highlight colour on a surface that allows one.
    func ribbonFocusRing(
        _ focused: Bool, radius: CGFloat = 6, inset: CGFloat = -4,
        tint: Color = RibbonPalette.focusRing
    ) -> some View {
        focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint.opacity(focused ? 1 : 0), lineWidth: 2)
                    .padding(inset)
                    .allowsHitTesting(false)
            )
    }
}
