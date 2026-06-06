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
            Section("Loopback Helper") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(HelperManager.label(for: app.helper.status))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Install / Enable") {
                        try? app.helper.install()
                    }
                    Button("Remove") {
                        try? app.helper.uninstall()
                    }
                    Spacer()
                    Button("Refresh") { app.helper.refresh() }
                }
                Text(
                    "Per-workspace loopback IPs require this signed root helper. "
                        + "Available once the signed build ships."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let err = app.registryError {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }
}
