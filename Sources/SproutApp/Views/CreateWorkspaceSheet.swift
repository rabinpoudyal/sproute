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
        NavigationStack {
            Form {
                Section {
                    TextField("Branch", text: $branch, prompt: Text("feature/login"))
                        .disabled(creating)
                    TextField("Base branch", text: $base)
                        .disabled(creating)
                }
                if creating {
                    Section("Progress") {
                        ForEach(project.createProgress) { step in
                            HStack(spacing: 10) {
                                stepIcon(step.state)
                                    .frame(width: 16)
                                Text(step.label)
                                    .foregroundStyle(step.state == .pending ? .secondary : .primary)
                                Spacer()
                            }
                        }
                    }
                } else {
                    Section("Preview") {
                        LabeledContent("Database", value: dbPreview)
                        LabeledContent("Ports", value: portSummary)
                        LabeledContent("Worktree", value: worktreePreview)
                    }
                }
                if let err = project.lastError {
                    Section {
                        ErrorBanner(error: err)
                    }
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                if creating {
                    logPane
                }
            }
            .navigationTitle("New Workspace")
            .navigationSubtitle(project.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(creating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { create() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(branch.isEmpty || base.isEmpty)
                    }
                }
            }
        }
        .frame(width: 480, height: creating ? 580 : 380)
        .onAppear { project.lastError = nil }
    }

    private var logPane: some View {
        VStack(spacing: 0) {
            Divider()
            LogConsoleView(buffer: project.logBuffer(branch: branch, process: "setup"))
                .frame(height: 180)
        }
    }

    @ViewBuilder private func stepIcon(_ state: CreateStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
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
