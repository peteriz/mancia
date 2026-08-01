import SwiftUI

/// One line of the readiness checklist: a state, what it is, and — when
/// something is missing — the control that fixes it.
///
/// The dot is never the only carrier of state; the words beside it always name
/// it, so the row survives a colour-blind reading and a screen reader.
enum ReadinessState {
    case ready(String)
    case attention(String)

    var text: String {
        switch self {
        case .ready(let text), .attention(let text): return text
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .attention: return .orange
        }
    }
}

struct ReadinessRow<Control: View>: View {
    let title: String
    let state: ReadinessState
    @ViewBuilder var control: () -> Control

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                control()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(state.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
