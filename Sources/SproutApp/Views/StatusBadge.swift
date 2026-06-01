import SwiftUI
import SproutEngine

extension WorkspaceStatus {
    var color: Color {
        switch self {
        case .creating, .tearingDown: return .orange
        case .running:                return .green
        case .stopped:                return .secondary
        case .crashed:                return .red
        }
    }

    var label: String {
        switch self {
        case .creating:    return "Setting up"
        case .running:     return "Running"
        case .stopped:     return "Idle"
        case .crashed:     return "Crashed"
        case .tearingDown: return "Tearing down"
        }
    }
}

/// Small colored dot + text used in the sidebar and detail header.
struct StatusBadge: View {
    let status: WorkspaceStatus
    var showText = true

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            if showText {
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
