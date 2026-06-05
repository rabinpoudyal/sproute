import SwiftUI
import AppKit
import SproutEngine

/// Full-width bottom drawer hosting a workspace's persistent interactive shell. The shell
/// session lives in `ProjectStore` (keyed by branch) and outlives this view, so closing the
/// drawer keeps the session + scrollback alive. A top edge drag handle resizes the drawer.
struct ShellDrawer: View {
    @ObservedObject var project: ProjectStore
    let item: WorkspaceItem
    @Binding var height: CGFloat
    let onClose: () -> Void

    private let minHeight: CGFloat = 120
    private let maxHeight: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            handle
            header
            Divider()
            content
        }
        .frame(height: height)
        .background(.background)
        .task(id: item.record.branch) { await project.openShell(item) }
    }

    private var handle: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Dragging up (negative translation) grows the drawer.
                        let next = height - value.translation.height
                        height = min(maxHeight, max(minHeight, next))
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize")
    }

    private var header: some View {
        HStack {
            Image(systemName: "terminal")
            Text("shell — \(item.record.branch)").font(.callout.bold())
            Spacer()
            Button(action: onClose) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Hide shell (⌘J)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        if let controller = project.shellController(branch: item.record.branch) {
            ConsoleView(controller: controller)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            VStack {
                Spacer()
                ProgressView()
                Text("Starting shell…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
