import SwiftUI
import SproutEngine

/// Editable form over a `ConfigDraft`, used both to edit an existing project's
/// `.sprout.toml` and to author a new one. Symlink sources are editable rows with
/// an inline content preview (read from `projectRoot` when present).
struct ConfigFormView<Extra: View>: View {
    @ObservedObject var draft: ConfigDraft
    /// Repo root used to preview symlink-source contents. `nil` when creating a new
    /// project (no folder/contents to read yet).
    var projectRoot: URL?
    var saveTitle: String = "Save"
    /// Throws to signal a save failure; the thrown error's message is surfaced inline.
    let onSave: (Config) throws -> Void
    /// When set (e.g. in a modal sheet), renders a Cancel button in the bottom bar.
    var onCancel: (() -> Void)? = nil
    /// Extra trailing sections (e.g. Doctor on the project overview).
    @ViewBuilder var extra: () -> Extra

    @State private var error: String?
    @State private var saved = false

    var body: some View {
        Form {
            projectSection
            worktreeSection
            databaseSection
            setupSection
            processesSection
            symlinkSection
            hooksSection
            extra()
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { saveBar }
    }

    // MARK: sections (single scrolling inspector, Xcode-style)

    @ViewBuilder private var projectSection: some View {
        Section("Project") {
            TextField("Name", text: $draft.projectName, prompt: Text("my-app"))
        }
    }

    @ViewBuilder private var worktreeSection: some View {
        Section("Worktree") {
            TextField("Base dir", text: $draft.baseDir, prompt: Text("../worktrees"))
            TextField("Branch prefix", text: $draft.branchPrefix, prompt: Text("feature/"))
        }
    }

    @ViewBuilder private var databaseSection: some View {
        Section("Database") {
            TextField("Create", text: $draft.dbCreate)
            TextField("Drop", text: $draft.dbDrop)
            TextField("URL template", text: $draft.dbURL)
        }
    }

    @ViewBuilder private var setupSection: some View {
        Section("Setup steps") {
            ForEach($draft.setup) { $step in
                HStack {
                    TextField("name", text: $step.name)
                        .frame(width: 110)
                    TextField("command", text: $step.command)
                        .font(.callout.monospaced())
                    Button(role: .destructive) {
                        removeStep(step.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove step")
                }
            }
            Button {
                draft.setup.append(.init(name: "", command: ""))
            } label: {
                Label("Add step", systemImage: "plus")
            }
        }
    }

    @ViewBuilder private var processesSection: some View {
        Section("Run processes") {
            ForEach($draft.processes) { $proc in
                HStack {
                    TextField("name", text: $proc.name)
                        .frame(width: 110)
                    TextField("command", text: $proc.command)
                        .font(.callout.monospaced())
                    TextField("port", text: $proc.port)
                        .frame(width: 60)
                    Button(role: .destructive) {
                        removeProcess(proc.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove process")
                }
            }
            Button {
                draft.processes.append(.init(name: "", command: "", port: ""))
            } label: {
                Label("Add process", systemImage: "plus")
            }
        }
    }

    @ViewBuilder private var symlinkSection: some View {
        Section {
            ForEach($draft.symlinkSources) { $source in
                SymlinkSourceRow(
                    path: $source.value,
                    projectRoot: projectRoot,
                    onDelete: { remove(source.id) })
            }
            Button {
                draft.symlinkSources.append(.init(value: ""))
            } label: {
                Label("Add source", systemImage: "plus")
            }
            TextField("Local file", text: $draft.localFile, prompt: Text(".env.local"))
        } header: {
            Text("Symlinked files")
        } footer: {
            Text(
                "Gitignored secrets identical across branches (e.g. config/master.key). "
                    + "Missing entries are skipped when linking.")
        }
    }

    @ViewBuilder private var hooksSection: some View {
        Section("Hooks (optional)") {
            TextField("Pre-teardown", text: $draft.preTeardown)
            TextField("Post-teardown", text: $draft.postTeardown)
        }
    }

    // MARK: save bar

    private var saveBar: some View {
        VStack(spacing: 8) {
            if let error {
                ErrorBanner(error: AppError(title: "Invalid configuration", detail: error))
            }
            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(saveTitle, action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .background(.bar)
    }

    private func remove(_ id: ConfigDraft.Source.ID) {
        draft.symlinkSources.removeAll { $0.id == id }
    }

    private func removeStep(_ id: ConfigDraft.Step.ID) {
        draft.setup.removeAll { $0.id == id }
    }

    private func removeProcess(_ id: ConfigDraft.ProcessRow.ID) {
        draft.processes.removeAll { $0.id == id }
    }

    private func save() {
        do {
            let config = try draft.build()
            try onSave(config)
            error = nil
            confirmSaved()
        } catch {
            self.error = error.localizedDescription
            saved = false
        }
    }

    /// Flash a transient "Saved" confirmation that clears itself.
    private func confirmSaved() {
        withAnimation { saved = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { saved = false }
        }
    }
}

extension ConfigFormView where Extra == EmptyView {
    init(
        draft: ConfigDraft, projectRoot: URL?, saveTitle: String = "Save",
        onSave: @escaping (Config) throws -> Void, onCancel: (() -> Void)? = nil
    ) {
        self.init(
            draft: draft, projectRoot: projectRoot, saveTitle: saveTitle,
            onSave: onSave, onCancel: onCancel, extra: { EmptyView() })
    }
}

/// One symlink-source row: editable path, delete, and a collapsed content preview
/// (read straight from the repo, so it shows what every workspace will link to).
private struct SymlinkSourceRow: View {
    @Binding var path: String
    var projectRoot: URL?
    let onDelete: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("config/master.key", text: $path)
                    .font(.callout.monospaced())
                if canPreview {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(expanded ? "Hide contents" : "Show contents")
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove source")
            }
            if expanded { preview }
        }
    }

    private var canPreview: Bool {
        guard let root = projectRoot, !path.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent(path).path)
    }

    @ViewBuilder private var preview: some View {
        switch contents {
        case .text(let s):
            ScrollView {
                Text(s)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(6)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .tooBig:
            Text("Not shown (binary or larger than 64 KB).")
                .font(.caption).foregroundStyle(.secondary)
        case .missing:
            Text("Not present in the project root.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private enum Contents {
        case text(String)
        case tooBig
        case missing
    }

    private var contents: Contents {
        guard let root = projectRoot,
            let data = try? Data(contentsOf: root.appendingPathComponent(path))
        else { return .missing }
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
            return .tooBig
        }
        return .text(text)
    }
}
