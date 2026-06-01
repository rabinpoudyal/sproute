import SwiftUI
import AppKit
import SproutEngine

/// Authors a new `.sprout.toml`: choose a folder, fill in the config form, then
/// write + register the project. Reuses `ConfigFormView` with a fresh template draft.
struct CreateProjectSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var draft = ConfigDraft.template()
    @State private var folder: URL?

    var body: some View {
        VStack(spacing: 0) {
            folderBar
            Divider()
            ConfigFormView(
                draft: draft,
                projectRoot: folder,
                saveTitle: "Create project",
                onSave: create,
                onCancel: { dismiss() })
        }
        .frame(width: 560, height: 640)
    }

    private var folderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
            if let folder {
                Text(folder.path)
                    .font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("Choose the project folder…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…", action: pickFolder)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK { folder = panel.url?.standardizedFileURL }
    }

    private func create(_ config: Config) throws {
        guard let folder else { throw CreateProjectError.noFolder }
        let existing = folder.appendingPathComponent(".sprout.toml")
        if FileManager.default.fileExists(atPath: existing.path) {
            throw CreateProjectError.alreadyExists
        }
        try app.createProject(at: folder, config: config)
        dismiss()
    }
}

private enum CreateProjectError: LocalizedError {
    case noFolder
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .noFolder:
            return "Choose the project folder first."
        case .alreadyExists:
            return "That folder already has a .sprout.toml — use “Add Project” instead."
        }
    }
}
