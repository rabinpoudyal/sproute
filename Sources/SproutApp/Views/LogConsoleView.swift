import SwiftUI
import SproutEngine

/// Inline, color-coded log console with autoscroll, pause, clear, and pop-out.
struct LogConsoleView: View {
    @ObservedObject var buffer: LogBuffer
    var onPopOut: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Logs").font(.headline)
                Spacer()
                Toggle(isOn: $buffer.paused) {
                    Label("Pause scroll", systemImage: buffer.paused ? "pause.fill" : "pause")
                }
                .toggleStyle(.button)
                Button { buffer.clear() } label: { Label("Clear", systemImage: "trash") }
                if let onPopOut {
                    Button(action: onPopOut) {
                        Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .labelStyle(.iconOnly)
            .padding(8)
            Divider()
            logScroll
        }
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(buffer.entries) { entry in
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(entry.source == .stderr ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: buffer.entries.count) {
                guard !buffer.paused, let last = buffer.entries.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// Standalone window content for a detached log view, looked up by target.
struct DetachedLogWindow: View {
    @EnvironmentObject var app: AppModel
    let target: LogTarget?

    var body: some View {
        Group {
            if let target,
               let project = app.projects.first(where: { $0.id == target.projectID }) {
                LogConsoleView(buffer: project.logBuffer(for: target.branch))
                    .navigationTitle("\(project.name) / \(target.branch)")
            } else {
                ContentUnavailableView("No Logs", systemImage: "doc.plaintext")
            }
        }
    }
}
