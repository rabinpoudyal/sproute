import SwiftUI
import SproutEngine

extension WorkspaceStatus {
    var color: Color {
        switch self {
        case .creating, .tearingDown: return .orange
        case .running: return .green
        case .stopped: return .secondary
        case .crashed: return .red
        }
    }

    var label: String {
        switch self {
        case .creating: return "Setting up"
        case .running: return "Running"
        case .stopped: return "Idle"
        case .crashed: return "Crashed"
        case .tearingDown: return "Tearing down"
        }
    }

    /// Distinct symbol per state so status is not conveyed by color alone
    /// (HIG accessibility — color-blind users).
    var symbol: String {
        switch self {
        case .creating, .tearingDown: return "circle.dotted"
        case .running: return "circle.fill"
        case .stopped: return "circle"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }
}

/// Small status glyph + text used in the sidebar and detail header. The glyph's
/// shape differs per state (not just color), and the badge carries an
/// accessibility label so VoiceOver announces the status.
struct StatusBadge: View {
    let status: WorkspaceStatus
    var showText = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbol)
                .font(.system(size: 9))
                .foregroundStyle(status.color)
            if showText {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.label)")
    }
}
