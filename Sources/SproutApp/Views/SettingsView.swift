import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Projects") {
                if app.projects.isEmpty {
                    Text("No projects registered.").foregroundStyle(.secondary)
                }
                ForEach(app.projects) { project in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name)
                            Text(project.rootURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            app.removeProject(project)
                        }
                    }
                }
            }
            LoopbackSettingsSection(helper: app.helper)
            if let err = app.registryError {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }
}

/// Observes `HelperManager` directly so its `@Published status` re-renders this
/// view — `SettingsView` only observes `AppModel`, which does not republish on
/// nested object changes. A single toggle installs/removes the daemon.
private struct LoopbackSettingsSection: View {
    @ObservedObject var helper: HelperManager
    @State private var helperError: String?

    var body: some View {
        Section("Loopback Helper") {
            Toggle("Per-workspace loopback IPs", isOn: enabledBinding)
            Text(HelperManager.label(for: helper.status))
                .font(.caption)
                .foregroundStyle(.secondary)
            if helper.status == .requiresApproval {
                Button("Open Login Items Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .font(.caption)
            }
            if let helperError {
                Text(helperError).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { helper.refresh() }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { helper.status == .enabled },
            set: { on in
                helperError = nil
                do {
                    try on ? helper.install() : helper.uninstall()
                } catch {
                    helperError = "\(error)"
                }
            })
    }
}
