import SwiftUI

/// Small controls shared by the ribbon and the floating panel.
///
/// These began as private helpers inside `EditPanelView`. The ribbon needs the
/// same affordances in a different register, so they moved here as internal
/// types with their colors injected — one definition, two call sites, rather
/// than a copy to keep in sync.

/// The specialized-preset dropdown inside the panel's field, to the left of the
/// run button. Quiet by default — the run button is the primary action — but it
/// lights up on hover so the affordance is discoverable.
///
/// The ribbon has no equivalent: its Action cell carries presets directly.
struct PresetMenuButton: View {
    let run: (PanelPreset) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(PanelPreset.all) { preset in
                Button {
                    run(preset)
                } label: {
                    Label(preset.title, systemImage: preset.action.symbol)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "text.badge.star")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(hovering ? Palette.text : Palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(hovering ? Palette.text.opacity(0.07) : .clear))
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Editing presets")
        .accessibilityLabel("Editing presets")
        .accessibilityIdentifier("PresetMenu")
    }
}

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
                .frame(minHeight: 26)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
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
                .frame(minHeight: 26)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Back / counter / forward through the iteration history. Identical on both
/// surfaces apart from its colors.
struct VersionNav: View {
    @Bindable var model: PanelModel
    var tint: Color = Palette.textSecondary
    var faint: Color = Palette.textFaint

    var body: some View {
        HStack(spacing: 6) {
            Button { model.onNavigate?(model.currentIndex - 1) } label: {
                Image(systemName: "chevron.backward").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.currentIndex == 0 ? faint : tint)
            .disabled(model.currentIndex == 0)
            .accessibilityLabel("Previous version")
            .accessibilityIdentifier("IterBack")

            Text("\(model.currentIndex + 1)/\(model.versionCount)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .accessibilityIdentifier("IterCounter")

            Button { model.onNavigate?(model.currentIndex + 1) } label: {
                Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.currentIndex >= model.versionCount - 1 ? faint : tint)
            .disabled(model.currentIndex >= model.versionCount - 1)
            .accessibilityLabel("Next version")
            .accessibilityIdentifier("IterForward")
        }
    }
}

/// The "working" signal: a comet of light travelling around a shape's edge,
/// with a soft blurred copy beneath it for the glow. The panel rides it on the
/// instruction field's capsule; the ribbon rides it on the Run control.
///
/// The lap is driven by `TimelineView(.animation)` off the wall clock rather
/// than a repeating `withAnimation`, because the motion lives in an angular
/// gradient — a `ShapeStyle`, which SwiftUI will not interpolate frame by frame
/// the way it does a geometry modifier. Reading the angle from the clock each
/// frame sidesteps that entirely and keeps the lap at a constant rate.
///
/// With Reduce Motion on, the comet is replaced by a still ring; the status
/// line's running verb carries the signal instead.
struct SwooshBorder<S: InsettableShape>: View {
    var shape: S
    var tint: Color
    var animated: Bool

    /// Seconds per lap. Slow enough to read as deliberate, quick enough that
    /// the surface never looks stalled.
    private let period: Double = 1.6
    private let lineWidth: CGFloat = 2

    var body: some View {
        if animated {
            TimelineView(.animation) { context in
                let lap = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let angle = Angle.degrees(lap * 360)
                ZStack {
                    comet(angle: angle).blur(radius: 4).opacity(0.75)
                    comet(angle: angle)
                }
            }
        } else {
            shape.strokeBorder(tint.opacity(0.5), lineWidth: lineWidth)
        }
    }

    /// A bright head fading back into a transparent tail, swept around the
    /// border.
    private func comet(angle: Angle) -> some View {
        shape.strokeBorder(
            AngularGradient(
                stops: [
                    .init(color: tint.opacity(0), location: 0),
                    .init(color: tint.opacity(0.2), location: 0.05),
                    .init(color: tint, location: 0.15),
                    .init(color: tint.opacity(0), location: 0.36),
                    .init(color: tint.opacity(0), location: 1),
                ],
                center: .center,
                angle: angle
            ),
            lineWidth: lineWidth
        )
    }
}
