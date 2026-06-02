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
                .help(buffer.paused ? "Resume autoscroll" : "Pause autoscroll")
                Button {
                    buffer.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear logs")
                if let onPopOut {
                    Button(action: onPopOut) {
                        Label("Pop Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .help("Open logs in a separate window")
                }
            }
            .labelStyle(.iconOnly)
            .padding(8)
            Divider()
            logScroll
        }
    }

    private func attributed(_ entry: LogBuffer.Entry) -> AttributedString {
        ANSIText.parse(entry.text, fallback: entry.source == .stderr ? .red : .primary)
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(buffer.entries) { entry in
                        Text(attributed(entry))
                            .font(.system(.caption, design: .monospaced))
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
                let project = app.projects.first(where: { $0.id == target.projectID })
            {
                LogConsoleView(
                    buffer: project.logBuffer(branch: target.branch, process: target.process)
                )
                .navigationTitle("\(project.name) / \(target.branch) / \(target.process)")
            } else {
                ContentUnavailableView("No Logs", systemImage: "doc.plaintext")
            }
        }
    }
}
