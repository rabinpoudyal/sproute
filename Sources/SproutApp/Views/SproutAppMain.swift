import SwiftUI
import AppKit

/// Identifies a detached log window: a process within a workspace branch within a project.
struct LogTarget: Identifiable, Hashable, Codable {
    let projectID: String
    let branch: String
    let process: String
    var id: String { "\(projectID)#\(branch)#\(process)" }
}

/// Forces a normal foreground app. Without this the `MenuBarExtra` can make the
/// process launch as an accessory (menu-bar) app, leaving the main window
/// non-key so text fields never receive keyboard input.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SproutAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        // Main control window.
        WindowGroup(id: "main") {
            MainWindow()
                .environmentObject(app)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { app.presentingNewProject = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Add Project…") { presentAddProjectPanel(app) }
                    .keyboardShortcut("o", modifiers: .command)
            }
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

        // Detached, per-session console windows.
        WindowGroup(for: ConsoleTarget.self) { $target in
            DetachedConsoleWindow(target: target)
                .environmentObject(app)
                .frame(minWidth: 560, minHeight: 360)
        }

        Settings {
            SettingsView()
                .environmentObject(app)
        }
    }

    private var menuBarSymbol: String {
        switch app.aggregateStatus {
        case .idle: return "leaf"
        case .running: return "leaf.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
