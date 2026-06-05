import Foundation
import SproutEngine

/// Editable, validatable mirror of `Config` for the config form. Numeric and list
/// fields are held as UI-friendly types (strings, identifiable rows) and converted
/// back to a `Config` via `build()`, which validates and throws on bad input.
@MainActor
final class ConfigDraft: ObservableObject {
    struct Source: Identifiable {
        let id = UUID()
        var value: String
    }
    struct Step: Identifiable {
        let id = UUID()
        var name: String
        var command: String
    }
    struct ProcessRow: Identifiable {
        let id = UUID()
        var name: String
        var command: String
        var port: String
    }

    @Published var projectName: String
    @Published var baseDir: String
    @Published var branchPrefix: String
    @Published var symlinkSources: [Source]
    @Published var localFile: String
    @Published var dbCreate: String
    @Published var dbDrop: String
    @Published var dbURL: String
    @Published var setup: [Step]
    @Published var processes: [ProcessRow]
    /// Carried through unchanged (no form UI yet) so saving never drops [[run.console]].
    private var consoles: [ConsoleConfig]
    @Published var preTeardown: String
    @Published var postTeardown: String

    init(_ c: Config) {
        projectName = c.project.name
        baseDir = c.worktree.baseDir
        branchPrefix = c.worktree.branchPrefix
        symlinkSources = c.env.symlinkSources.map { Source(value: $0) }
        localFile = c.env.localFile
        dbCreate = c.database.createCommand
        dbDrop = c.database.dropCommand
        dbURL = c.database.urlTemplate
        setup = c.setup.map { Step(name: $0.name, command: $0.command) }
        processes = c.run.processes.map {
            ProcessRow(name: $0.name, command: $0.command, port: $0.port.map(String.init) ?? "")
        }
        consoles = c.run.consoles
        preTeardown = c.hooks.preTeardown ?? ""
        postTeardown = c.hooks.postTeardown ?? ""
    }

    /// A sensible starting point for a brand-new project.
    static func template() -> ConfigDraft {
        ConfigDraft(
            Config(
                project: ProjectConfig(name: ""),
                worktree: WorktreeConfig(baseDir: "../worktrees", branchPrefix: "feature/"),
                env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
                database: DatabaseConfig(
                    createCommand: "createdb {{db_name}}",
                    dropCommand: "dropdb --if-exists {{db_name}}",
                    urlTemplate: "postgres://localhost/{{db_name}}"),
                setup: [],
                run: RunConfig(processes: []),
                hooks: HooksConfig()))
    }

    /// Validate and assemble a `Config`. Throws `DraftError` with a human message
    /// on the first problem found.
    func build() throws -> Config {
        let name = projectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw DraftError.empty("Project name") }
        guard !baseDir.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DraftError.empty("Worktree base dir")
        }

        let sources =
            symlinkSources
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let steps = try setup.map { row -> SetupStep in
            let n = row.name.trimmingCharacters(in: .whitespaces)
            let c = row.command.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !c.isEmpty else { throw DraftError.incompleteStep }
            return SetupStep(name: n, command: c)
        }
        let procs = try processes.compactMap { row -> ProcessConfig? in
            let n = row.name.trimmingCharacters(in: .whitespaces)
            let c = row.command.trimmingCharacters(in: .whitespaces)
            let pStr = row.port.trimmingCharacters(in: .whitespaces)
            if n.isEmpty, c.isEmpty, pStr.isEmpty { return nil }  // drop fully-blank rows
            guard !n.isEmpty, !c.isEmpty else { throw DraftError.incompleteProcess }
            var port: Int? = nil
            if !pStr.isEmpty {
                guard let v = Int(pStr) else { throw DraftError.notAnInt("Port for \(n)") }
                port = v
            }
            return ProcessConfig(name: n, command: c, port: port)
        }

        func optional(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }

        return Config(
            project: ProjectConfig(name: name),
            worktree: WorktreeConfig(baseDir: baseDir, branchPrefix: branchPrefix),
            env: EnvConfig(symlinkSources: sources, localFile: localFile),
            database: DatabaseConfig(
                createCommand: dbCreate, dropCommand: dbDrop, urlTemplate: dbURL),
            setup: steps,
            run: RunConfig(processes: procs, consoles: consoles),
            hooks: HooksConfig(
                preTeardown: optional(preTeardown), postTeardown: optional(postTeardown)))
    }
}

enum DraftError: LocalizedError {
    case empty(String)
    case notAnInt(String)
    case incompleteStep
    case incompleteProcess

    var errorDescription: String? {
        switch self {
        case .empty(let field): return "\(field) cannot be empty."
        case .notAnInt(let field): return "\(field) must be a whole number."
        case .incompleteStep: return "Every setup step needs both a name and a command."
        case .incompleteProcess: return "Every run process needs both a name and a command."
        }
    }
}
