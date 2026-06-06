import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sprout").font(.headline)
                Spacer()
                Text("\(app.runningCount) running")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()

            if app.projects.allSatisfy({ $0.workspaces.isEmpty }) {
                Text("No workspaces").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(app.projects) { project in
                if !project.workspaces.isEmpty {
                    Text(project.name)
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(project.workspaces) { item in
                        MenuBarRow(project: project, item: item)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open Window") { openWindow(id: "main") }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }
}

struct MenuBarRow: View {
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(status: item.record.status, showText: false)
            Text(item.record.branch).lineLimit(1)
            Spacer()
            Text(":\(item.record.port)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if busy {
                ProgressView().controlSize(.small)
            } else if item.record.status == .running {
                Button {
                    toggle { await project.stopAll(item) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel("Stop \(item.record.branch)")
            } else {
                Button {
                    toggle { await project.startAll(item) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(item.orphaned)
                .accessibilityLabel("Start \(item.record.branch)")
            }
        }
        .buttonStyle(.borderless)
    }

    private func toggle(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work(); busy = false
        }
    }
}
