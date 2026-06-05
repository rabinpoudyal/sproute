import SwiftUI
import SproutEngine

struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var project: ProjectStore

    @State private var branch = ""
    @State private var base = "origin/develop"
    @State private var creating = false

    private var slug: String { TemplateContext.slugify(branch) }
    private var dbPreview: String { branch.isEmpty ? "—" : "\(project.name)_\(slug)" }
    private var worktreePreview: String {
        branch.isEmpty ? "—" : "\(project.config.worktree.baseDir)/\(slug)"
    }
    private var portSummary: String {
        let plan = portPlan(project.config.run.processes)
        if plan.isEmpty { return "none" }
        return plan.sorted { $0.value < $1.value }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "  ")
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
                LabeledContent("Ports", value: portSummary)
                LabeledContent("Worktree", value: worktreePreview)
            }
            .formStyle(.grouped)

            if creating {
                Text("Setting up…").font(.caption).foregroundStyle(.secondary)
                LogConsoleView(buffer: project.logBuffer(branch: branch, process: "setup"))
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let err = project.lastError {
                ErrorBanner(error: err)
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
