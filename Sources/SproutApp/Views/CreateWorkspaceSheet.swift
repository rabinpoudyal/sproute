import SwiftUI
import SproutEngine

struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var project: ProjectStore

    @State private var branch = ""
    @State private var base = "main"
    @State private var creating = false

    private var slug: String { TemplateContext.slugify(branch) }
    private var dbPreview: String { branch.isEmpty ? "—" : "\(project.name)_\(slug)" }
    private var worktreePreview: String {
        branch.isEmpty ? "—" : "\(project.config.worktree.baseDir)/\(slug)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace in \(project.name)").font(.title3.bold())

            Form {
                TextField("Branch", text: $branch, prompt: Text("feature/login"))
                    .disabled(creating)
                TextField("Base branch", text: $base)
                    .disabled(creating)
                LabeledContent("Database", value: dbPreview)
                LabeledContent("Port",
                               value: "auto (\(project.config.port.lower)–\(project.config.port.upper))")
                LabeledContent("Worktree", value: worktreePreview)
            }
            .formStyle(.grouped)

            if creating {
                Text("Setting up…").font(.caption).foregroundStyle(.secondary)
                LogConsoleView(buffer: project.logBuffer(for: branch))
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let err = project.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            HStack {
                Button("Cancel") { dismiss() }.disabled(creating)
                Spacer()
                if creating { ProgressView().controlSize(.small) }
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(branch.isEmpty || base.isEmpty || creating)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func create() {
        creating = true
        project.lastError = nil
        Task {
            await project.create(base: base, branch: branch)
            creating = false
            if project.lastError == nil { dismiss() }
        }
    }
}
