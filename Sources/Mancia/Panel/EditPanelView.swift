import AppKit
import SwiftUI

/// The floating edit panel — the "sharp & effective" design: a warm cream/ink
/// surface with one decisive vermilion accent.
///
/// The panel is a single command row. Everything the user can do lives in the
/// instruction field: type a change and press Return, press the accent run
/// button (which means *Improve* while the field is empty), or pick a
/// specialized preset from the dropdown beside it — with anything typed riding
/// along as extra guidance for that preset.
///
/// Fixed size, never relayouts mid-use. While a request runs the field dims and
/// locks and an indeterminate bar sweeps its base edge, so the panel reads as
/// fast and working, not frozen. The one-line status at the bottom swaps
/// between idle / running / confirm / applied / error and carries the
/// secondary actions for each.
struct EditPanelView: View {
    @Bindable var model: PanelModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 360
    /// The field's inset around the run button, on the trailing and both
    /// vertical edges. A circle inset evenly inside a capsule is concentric with
    /// it by construction, so the two curves stay parallel at any height.
    private let fieldInset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
                .padding(.bottom, 11)

            field

            statusLine
                .padding(.top, 10)
                .frame(height: 22)
        }
        .padding(12)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 14)
        .onExitCommand { model.onCancel?() }
        .onAppear { fieldFocused = true }
        .onChange(of: model.sessionSeq) { fieldFocused = true }
        .onChange(of: model.focusSeq) { fieldFocused = true }
    }

    private var isRunning: Bool { model.phase == .running }
    private var isConfirming: Bool { model.phase == .confirm }
    /// The instruction field is inert while a request runs or a whole-document
    /// replacement is awaiting confirmation.
    private var fieldLocked: Bool { isRunning || isConfirming }
    private var hasCustomInstruction: Bool {
        !model.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Brand row

    private var brandRow: some View {
        HStack(spacing: 7) {
            BrandMark.view(size: 15)
            Text("Mancia")
                .font(.system(size: 13, weight: .bold))
                .tracking(-0.1)
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            scopeCaption
        }
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private var scopeCaption: some View {
        if model.capturing {
            Text("Reading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        } else if model.hasSelection {
            Menu {
                Button("Selection · \(model.selectionCharCount)") { model.scope = .selection }
                Button("Entire document") { model.scope = .document }
            } label: {
                HStack(spacing: 3) {
                    Text(scopeText)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Scope")
            .accessibilityIdentifier("Scope")
        } else {
            Text("Entire document")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var scopeText: String {
        switch model.scope {
        case .selection: return "Selection · \(model.selectionCharCount)"
        case .document: return "Entire document"
        }
    }

    // MARK: - Field

    /// The panel's one control: instruction text, the preset dropdown, and the
    /// accent run button. The running progress bar rides the field's base edge
    /// *outside* the dimming applied to the contents, so the surface stays lit
    /// while its controls read as inert.
    private var field: some View {
        HStack(spacing: 4) {
            TextField("", text: $model.instruction, prompt: placeholder)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text)
                .focused($fieldFocused)
                .onSubmit { model.runPrimary() }
                .accessibilityLabel("Custom instruction")
                .accessibilityIdentifier("CustomInstruction")
                .padding(.trailing, 4)

            PresetMenuButton { model.runPreset($0) }

            runButton
        }
        .opacity(fieldLocked ? 0.42 : 1)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .padding(.leading, 11)
        .padding(.trailing, fieldInset)
        .padding(.vertical, fieldInset)
        .background(fieldShape.fill(Palette.raised))
        .clipShape(fieldShape)
        .overlay(fieldShape.strokeBorder(fieldStroke, lineWidth: 1))
        .overlay {
            if isRunning {
                SwooshBorder(tint: Palette.accent, animated: !reduceMotion)
            }
        }
        .disabled(fieldLocked)
    }

    /// A capsule rather than a fixed radius: it stays fully round whatever the
    /// row's height resolves to, so the shape can't drift if the controls inside
    /// it are ever resized.
    private var fieldShape: Capsule {
        Capsule(style: .continuous)
    }

    /// The field is focused for nearly the whole session, so focus is carried by
    /// a firmer neutral edge rather than the accent — the accent stays reserved
    /// for the run button and the status dot, where it means something.
    private var fieldStroke: Color {
        fieldFocused && !fieldLocked ? Palette.text.opacity(0.3) : Palette.border
    }

    private var placeholder: Text {
        Text("Describe a change…").foregroundColor(Palette.textFaint)
    }

    /// The primary action. Always live: an empty field means Improve, a typed
    /// one means run that instruction — the same routing Return uses.
    ///
    /// A circle: the shape a capsule field resolves to once it is inset evenly
    /// on three sides, so the button echoes the field rather than cutting
    /// against it.
    private var runButton: some View {
        Button { model.runPrimary() } label: {
            ZStack {
                Circle().fill(Palette.accent)
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(runTitle)
        .accessibilityLabel(runTitle)
        .accessibilityIdentifier("Run")
    }

    private var runTitle: String {
        hasCustomInstruction ? "Run your instruction" : "Improve"
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .idle: idleStatus
        case .running: runningStatus
        case .confirm: confirmStatus
        case .applied: appliedStatus
        case .error: errorStatus
        }
    }

    /// Split across the row: the state label stays anchored on the left, the
    /// hint sits on the right under the run button it describes.
    private var idleStatus: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
            Text(model.capturing ? "Reading selection…" : "Ready")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !model.capturing {
                Text(idleHint)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 1)
    }

    /// Teaches what Return does right now — it changes as the user types, which
    /// is the only cue that an empty field runs Improve. The typed variant does
    /// not name the target: the instruction is visible directly above it, and
    /// the scope caption already says what the edit will touch.
    private var idleHint: String {
        if hasCustomInstruction { return "↵ runs your instruction" }
        return model.scope == .selection ? "↵ improves your selection" : "↵ improves the whole document"
    }

    private var runningStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
            Text("\(runningLabel)…")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            GhostButton("Cancel") { model.onCancelRun?() }
                .accessibilityIdentifier("Cancel")
        }
        .padding(.horizontal, 1)
    }

    /// The verb shown while a request runs. Stays honest during the brief
    /// background-capture window before the provider call begins.
    private var runningLabel: String {
        if model.capturing { return "Reading selection" }
        return model.runningTitle.isEmpty ? "Improving" : model.runningTitle
    }

    /// Awaiting confirmation before a whole-document overwrite. Shows the size
    /// change as a signal (e.g. a document collapsing to a few characters), and
    /// carries the accent confirm action — Return does the same thing.
    private var confirmStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
            Text("Review · \(ApplyConfirmation.summary(originalCharacters: model.pendingOriginalCharCount, resultCharacters: model.pendingResultCharCount))")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            GhostButton("Cancel") { model.onCancelRun?() }
                .accessibilityIdentifier("ConfirmCancel")
            AccentButton("Replace ↵") { model.onConfirmApply?() }
                .accessibilityLabel("Replace document")
                .accessibilityIdentifier("ReplaceDocument")
        }
        .padding(.horizontal, 1)
    }

    /// No close button: Esc dismisses the panel (and in hybrid mode it closes
    /// itself after a beat), so the row is left to the result and the version
    /// navigation.
    private var appliedStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.applied).frame(width: 7, height: 7)
            Text("Improved")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            if model.versionCount > 1 {
                versionNav
            }
        }
        .padding(.horizontal, 1)
    }

    private var versionNav: some View {
        HStack(spacing: 6) {
            Button { model.onNavigate?(model.currentIndex - 1) } label: {
                Image(systemName: "chevron.backward").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.currentIndex == 0 ? Palette.textFaint : Palette.textSecondary)
            .disabled(model.currentIndex == 0)
            .accessibilityLabel("Previous version")
            .accessibilityIdentifier("IterBack")

            Text("\(model.currentIndex + 1)/\(model.versionCount)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("IterCounter")

            Button { model.onNavigate?(model.currentIndex + 1) } label: {
                Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.currentIndex >= model.versionCount - 1 ? Palette.textFaint : Palette.textSecondary)
            .disabled(model.currentIndex >= model.versionCount - 1)
            .accessibilityLabel("Next version")
            .accessibilityIdentifier("IterForward")
        }
    }

    private var errorStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.errorDot).frame(width: 7, height: 7)
            Text(model.errorText.isEmpty ? "Provider failed" : model.errorText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Palette.error)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            GhostButton("Close") { model.onCancel?() }
                .accessibilityIdentifier("Close")
            GhostButton("Retry", tint: Palette.error) { model.onRetry?() }
                .accessibilityIdentifier("Retry")
        }
        .padding(.horizontal, 1)
    }
}

/// The specialized-preset dropdown inside the field, to the left of the run
/// button. Quiet by default — the run button is the primary action — but it
/// lights up on hover so the affordance is discoverable.
private struct PresetMenuButton: View {
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

/// A small hairline-bordered secondary button used in the status line.
private struct GhostButton: View {
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A small filled-accent button for the one decisive action in a status row —
/// today, confirming a whole-document replacement.
private struct AccentButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Palette.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The panel's "working" signal: a comet of accent light travelling around the
/// field's capsule edge, with a soft blurred copy beneath it for the glow.
///
/// The lap is driven by `TimelineView(.animation)` off the wall clock rather
/// than a repeating `withAnimation`, because the motion lives in an angular
/// gradient — a `ShapeStyle`, which SwiftUI will not interpolate frame by frame
/// the way it does a geometry modifier. Reading the angle from the clock each
/// frame sidesteps that entirely and keeps the lap at a constant rate.
///
/// With Reduce Motion on, the comet is replaced by a still accent ring; the
/// status line's running verb carries the signal instead.
private struct SwooshBorder: View {
    var tint: Color
    var animated: Bool

    /// Seconds per lap. Slow enough to read as deliberate, quick enough that
    /// the panel never looks stalled.
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
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.5), lineWidth: lineWidth)
        }
    }

    /// A bright head fading back into a transparent tail, swept around the
    /// capsule's border.
    private func comet(angle: Angle) -> some View {
        Capsule(style: .continuous)
            .strokeBorder(
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
