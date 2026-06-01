import SwiftUI

/// Identifies a detached log window: a workspace branch within a project.
struct LogTarget: Identifiable, Hashable, Codable {
    let projectID: String
    let branch: String
    var id: String { "\(projectID)#\(branch)" }
}

@main
struct SproutAppMain: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        // Main control window.
        WindowGroup(id: "main") {
            MainWindow()
                .environmentObject(app)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu-bar surface.
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(app)
                .frame(width: 320)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        // Detached, per-workspace log windows.
        WindowGroup(for: LogTarget.self) { $target in
            DetachedLogWindow(target: target)
                .environmentObject(app)
                .frame(minWidth: 520, minHeight: 320)
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }

    private var menuBarSymbol: String {
        switch app.aggregateStatus {
        case .idle:    return "leaf"
        case .running: return "leaf.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }
}
