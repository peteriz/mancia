import SwiftUI

/// Small controls shared by the ribbon's command row, status strip and review
/// gate.
///
/// These began as private helpers inside the floating panel's view. When the
/// ribbon replaced it they moved here as internal types with their colors
/// injected, so a control used in more than one register has one definition
/// rather than a copy to keep in sync.

/// A small hairline-bordered secondary button used in a status row.
struct GhostButton: View {
    let title: String
    var tint: Color
    let action: () -> Void

    init(_ title: String, tint: Color = Palette.textSecondary, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.4), lineWidth: 1))
                // The label is 15pt tall; the spec's 28pt minimum hit target is
                // reached by the shape, not by the ink.
                .frame(minHeight: 28)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(title)
    }
}

/// A small filled button for the one decisive action in a status row — today,
/// confirming a whole-document replacement.
struct AccentButton: View {
    let title: String
    var fill: Color
    var foreground: Color
    let action: () -> Void

    init(
        _ title: String,
        fill: Color = Palette.accent,
        foreground: Color = Palette.onAccent,
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(fill))
                .frame(minHeight: 28)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The "working" signal: a spark of light running around a shape's edge over a
/// steady ember, both spilling onto the surface behind them. The panel rode it
/// on the instruction field's capsule; the ribbon rides it on the primary action.
///
/// The lap is driven by `TimelineView(.animation)` off the wall clock rather
/// than a repeating `withAnimation`, which keeps the rate constant however the
/// rest of the lane is animating and lets the effect start mid-lap without a
/// jump.
///
/// The spark is a run of trimmed segments, not an angular gradient. A gradient
/// sweeps at a constant rate about the *centre*, so on a control half again as
/// wide as it is tall the light crawls along the long edges and snaps across
/// the short ones — a wobble rather than a lap, and one that only got more
/// obvious as the lap got quicker. `trim` measures the path by its own length,
/// so the light holds one speed the whole way round.
///
/// With Reduce Motion on the spark is dropped and the ember comes up to full,
/// leaving a lit border rather than a moving one; the status line's running
/// verb carries the signal either way.
struct SwooshBorder<S: InsettableShape>: View {
    var shape: S
    var tint: Color
    var animated: Bool
    /// The colour of the spark's head.
    ///
    /// Defaults to `tint`, which is what the panel wanted: a vermilion comet on
    /// a dark field. Over a fill of the tint's own colour — Run's — vermilion
    /// light on vermilion is the effect disappearing, so a surface in that
    /// position passes a light instead and keeps the tail vermilion.
    var head: Color?
    /// How far the glow spills outside the shape. Zero keeps the whole effect
    /// inside the border, which is right when it rides a field the rest of the
    /// surface is not crowding. Run is a small bright object on a dark lane and
    /// the halo is the part of the signal that carries across the lane.
    var halo: CGFloat = 0
    var lineWidth: CGFloat = 2

    /// Seconds per lap. Slow enough to read as deliberate, quick enough that
    /// the surface never looks stalled. It was 1.6s while this was a thin edge
    /// on a dark field; carrying a glow, and travelling evenly, that read as
    /// languid, and the lap came down to just under a second.
    private let period: Double = 0.925
    /// The tail, as a fraction of the perimeter, and the number of segments it
    /// is drawn in — enough that the falloff reads as a fade rather than as a
    /// dashed line, few enough to stay cheap sixty times a second.
    private let tail: Double = 0.3
    private let tailSteps = 7
    /// The bright tip, also as a fraction of the perimeter. Short: it is the
    /// thing the eye tracks, and a long one is a moving stripe.
    private let headLength: Double = 0.045

    private var headColor: Color { head ?? tint }

    var body: some View {
        ZStack {
            if halo > 0 { ember }
            if animated {
                TimelineView(.animation) { context in
                    spark(
                        at: context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period)
                }
            } else {
                shape.strokeBorder(headColor.opacity(0.55), lineWidth: lineWidth)
            }
        }
    }

    /// The steady part of the signal, under the spark.
    ///
    /// Without it the control is only legibly busy where the light happens to
    /// be standing, and a lane that gets read at a glance has to hold its state
    /// in every frame, not in the lucky ones. It is also what keeps the Reduce
    /// Motion fallback from reading as a second focus ring: focus is a crisp
    /// cream edge and nothing else, busy is a lit button.
    private var ember: some View {
        shape.inset(by: -halo)
            .stroke(tint, lineWidth: lineWidth + halo)
            .blur(radius: halo * 1.8)
            .opacity(animated ? 0.3 : 0.85)
    }

    /// The moving part: the same trail three times over — spilled and heavily
    /// blurred for what lands on the surface behind, softly blurred for the
    /// bloom, and crisp on the edge itself.
    private func spark(at lap: Double) -> some View {
        ZStack {
            if halo > 0 {
                // Vermilion, not the head colour: past the border this is light
                // in the air, and it is the accent that has to carry across the
                // lane. Struck outside the shape by `inset`, which opens the
                // corner radius with it — `padding` would leave the glow's
                // corners tighter than the ones they are supposed to be lighting.
                trail(on: shape.inset(by: -halo), at: lap, width: lineWidth + halo, head: tint)
                    .blur(radius: halo * 1.8)
                    .opacity(0.9)
            }
            trail(on: edge, at: lap, width: lineWidth, head: headColor)
                .blur(radius: 3)
                .opacity(0.85)
            // The tip's own bloom, spread over the fill it is crossing. Without
            // it the head is a bright dash lying on the button; light coming off
            // it is what makes the same shape read as hot.
            arc(edge, from: lap - headLength, to: lap, color: headColor, width: lineWidth * 2.4)
                .blur(radius: 5)
                .opacity(0.55)
            trail(on: edge, at: lap, width: lineWidth, head: headColor)
        }
    }

    /// The stroke sits inside the shape's own outline, the way `strokeBorder`
    /// would — `trim` is a `Shape` operation, so the inset has to be taken by
    /// hand.
    private var edge: S.InsetShape { shape.inset(by: lineWidth / 2) }

    /// A bright head with a tail falling away behind it.
    ///
    /// Drawn as segments because a stroke carries no gradient along its own
    /// length: each step back from the head is dimmer, on a square falloff, so
    /// most of the tail's light sits just behind the tip.
    private func trail<T: Shape>(
        on path: T, at lap: Double, width: CGFloat, head: Color
    ) -> some View {
        ZStack {
            ForEach(0..<tailSteps, id: \.self) { step in
                let near = Double(step) / Double(tailSteps)
                let far = Double(step + 1) / Double(tailSteps)
                arc(
                    path, from: lap - tail * far, to: lap - tail * near,
                    color: tint.opacity(pow(1 - near, 2)), width: width)
            }
            arc(path, from: lap - headLength, to: lap, color: head, width: width)
        }
    }

    /// A slice of the path between two lap fractions. `trim` clamps to `0...1`
    /// and will not wrap, so a slice crossing the seam is drawn as its two
    /// halves; round caps close the joint.
    @ViewBuilder
    private func arc<T: Shape>(
        _ path: T, from: Double, to: Double, color: Color, width: CGFloat
    ) -> some View {
        let style = StrokeStyle(lineWidth: width, lineCap: .round)
        let start = from - from.rounded(.down)
        let end = to - to.rounded(.down)
        if start <= end {
            path.trim(from: start, to: end).stroke(color, style: style)
        } else {
            ZStack {
                path.trim(from: start, to: 1).stroke(color, style: style)
                path.trim(from: 0, to: end).stroke(color, style: style)
            }
        }
    }
}

// MARK: - Focus ring

extension View {
    /// The lane's focus ring.
    ///
    /// A firmer neutral edge, never the accent: vermilion appears exactly once
    /// per surface and spending it on focus would empty it of meaning. Drawn
    /// outside the control so it never reflows the cell it belongs to.
    ///
    /// The system effect is switched off with it — left on, AppKit draws its
    /// blue ring over the top, which is the system accent by another name and
    /// reads as a second highlight colour on a surface that allows one.
    func ribbonFocusRing(
        _ focused: Bool, radius: CGFloat = 6, inset: CGFloat = -4
    ) -> some View {
        focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(RibbonPalette.text.opacity(focused ? 0.35 : 0), lineWidth: 2)
                    .padding(inset)
                    .allowsHitTesting(false)
            )
    }
}
