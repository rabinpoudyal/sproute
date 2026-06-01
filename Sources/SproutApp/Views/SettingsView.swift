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
            if let err = app.registryError {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
    }
}
