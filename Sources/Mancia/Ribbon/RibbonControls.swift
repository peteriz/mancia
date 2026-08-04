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

/// The working signal: a comet running the pressed control's border.
///
/// The steady track and every moving layer use `edge`, the exact path produced
/// by the shape inset by half this effect's line width. Keeping that geometry
/// inside one component matters: previously the static border was a separate
/// 1pt `strokeBorder` while the comet followed a 2pt inset path, so their
/// centerlines differed by half a point and the light visibly wandered off the
/// button edge.
///
/// The lap is driven by `TimelineView(.animation)` off the wall clock rather
/// than a repeating `withAnimation`, which keeps the rate constant however the
/// rest of the lane is animating and lets the effect start mid-lap without a
/// jump. Reduce Motion replaces the comet with the same steady lit track.
struct SwooshBorder<S: InsettableShape>: View {
    var shape: S
    var tint: Color
    var animated: Bool
    var head: Color?
    var lineWidth: CGFloat = 2

    private let period: Double = 0.925
    private let tail: Double = 0.3
    private let tailSteps = 20
    private let headLength: Double = 0.045

    private var headColor: Color { head ?? tint }
    private var edge: S.InsetShape { shape.inset(by: lineWidth / 2) }

    var body: some View {
        ZStack {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    spark(
                        at: context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period)
                }
            } else {
                edge.stroke(tint.opacity(0.8), lineWidth: lineWidth)
            }
        }
        // The light belongs to the button, not the lane around it.
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    private func spark(at lap: Double) -> some View {
        ZStack {
            // The original soft bloom, but clipped to the button and centered
            // on the same edge as the crisp trail.
            trail(on: edge, at: lap, width: lineWidth * 1.8, head: headColor)
                .blur(radius: 2)
                .opacity(0.7)
            trail(on: edge, at: lap, width: lineWidth, head: headColor)
            arc(
                edge,
                from: lap - headLength * 0.55,
                to: lap,
                color: .white.opacity(0.9),
                width: lineWidth * 0.7)
        }
    }

    private func trail<T: Shape>(
        on path: T,
        at lap: Double,
        width: CGFloat,
        head: Color
    ) -> some View {
        ZStack {
            ForEach(0..<tailSteps, id: \.self) { step in
                let near = Double(step) / Double(tailSteps)
                let far = Double(step + 1) / Double(tailSteps)
                arc(
                    path,
                    from: lap - tail * far,
                    to: lap - tail * near,
                    color: tint.opacity(pow(1 - near, 1.8)),
                    width: width,
                    cap: .butt)
            }
            arc(
                path,
                from: lap - headLength,
                to: lap,
                color: head,
                width: width)
        }
    }

    @ViewBuilder
    private func arc<T: Shape>(
        _ path: T,
        from: Double,
        to: Double,
        color: Color,
        width: CGFloat,
        cap: CGLineCap = .round
    ) -> some View {
        let style = StrokeStyle(lineWidth: width, lineCap: cap)
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
