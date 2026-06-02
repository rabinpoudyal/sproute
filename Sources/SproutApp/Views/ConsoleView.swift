import AppKit
import SwiftTerm
import SwiftUI

/// Embeds a session's persistent SwiftTerm `TerminalView`. The controller owns the view
/// (it survives this representable being recreated on tab switches), so we just hand the
/// existing NSView back to SwiftUI.
struct ConsoleView: NSViewRepresentable {
    let controller: ConsoleSessionController

    func makeNSView(context: Context) -> TerminalView { controller.terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

/// Identifies a detached console window: a session within a project.
struct ConsoleTarget: Identifiable, Hashable, Codable {
    let projectID: String
    let sessionID: UUID
    var id: String { "\(projectID)#\(sessionID.uuidString)" }
}

/// Standalone window content for a popped-out console, looked up by target.
struct DetachedConsoleWindow: View {
    @EnvironmentObject var app: AppModel
    let target: ConsoleTarget?

    var body: some View {
        Group {
            if let target,
                let project = app.projects.first(where: { $0.id == target.projectID }),
                let controller = project.consoleController(id: target.sessionID)
            {
                ConsoleView(controller: controller)
                    .navigationTitle("\(project.name) console")
            } else {
                ContentUnavailableView("No Console", systemImage: "terminal")
            }
        }
    }
}
