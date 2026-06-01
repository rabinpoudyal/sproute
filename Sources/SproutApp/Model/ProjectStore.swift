import Foundation
import SproutEngine

/// A workspace record paired with reconcile-derived liveness info, for display.
struct WorkspaceItem: Identifiable, Equatable {
    var record: WorkspaceRecord
    var orphaned: Bool  // worktree directory missing on disk
    var id: UUID { record.id }
}

/// Identifies one supervised process within a workspace branch.
private struct ProcessKey: Hashable {
    let branch: String
    let name: String
}

/// View-model for a single registered project. Wraps the headless engine
/// (`WorkspaceManager` + friends) and exposes UI-friendly state and actions.
@MainActor
final class ProjectStore: ObservableObject, Identifiable {
    nonisolated let id: String  // normalized root path
    let rootURL: URL
    let config: Config

    @Published private(set) var workspaces: [WorkspaceItem] = []
    @Published private(set) var doctor: [ToolCheck] = []
    @Published var lastError: AppError?

    private let shell = LoginShellRunner()
    private let renderer = TemplateRenderer()
    private let store: StateStore
    private let manager: WorkspaceManager

    private var buffers: [ProcessKey: LogBuffer] = [:]
    private var supervisors: [ProcessKey: ServerSupervisor] = [:]

    var name: String { config.project.name }

    init(rootURL: URL, config: Config) {
        self.rootURL = rootURL.standardizedFileURL
        self.id = self.rootURL.path
        self.config = config
        let store = JSONStateStore(fileURL: SproutPaths.stateFile(projectName: config.project.name))
        self.store = store
        self.manager = ProjectStore.makeManager(
            config: config, store: store,
            shell: shell, renderer: renderer)
    }

    private static func makeManager(
        config: Config, store: StateStore,
        shell: ShellRunner, renderer: TemplateRenderer
    ) -> WorkspaceManager {
        WorkspaceManager(
            git: GitService(shell: shell),
            portAllocator: PortAllocator(
                config: config.port, store: store, prober: BindPortProber()),
            database: DatabaseService(shell: shell, renderer: renderer),
            envLinker: EnvLinker(fs: RealFileSystem()),
            fs: RealFileSystem(),
            setupRunner: SetupRunner(shell: shell, renderer: renderer),
            store: store,
            checker: PosixProcessChecker(),
            terminator: PosixProcessTerminator(),
            renderer: renderer,
            shell: shell)
    }

    // MARK: - Logs

    func logBuffer(branch: String, process: String) -> LogBuffer {
        let key = ProcessKey(branch: branch, name: process)
        if let b = buffers[key] { return b }
        let b = LogBuffer(id: "\(branch)#\(process)")
        buffers[key] = b
        return b
    }

    private func onLog(branch: String, process: String) -> @Sendable (LogLine) -> Void {
        let buffer = logBuffer(branch: branch, process: process)
        return { line in Task { @MainActor in buffer.append(line) } }
    }

    // MARK: - Reads

    func refresh() {
        do {
            let reconciled = try manager.reconcile()
            workspaces = reconciled.map { WorkspaceItem(record: $0.record, orphaned: $0.orphaned) }
        } catch {
            lastError = AppError(error)
        }
    }

    func runDoctor() async {
        doctor = await DoctorService(shell: shell)
            .check(tools: ["git", "createdb", "dropdb", "node"], cwd: rootURL)
    }

    func isDirty(_ item: WorkspaceItem) async -> Bool {
        (try? await GitService(shell: shell)
            .isDirty(worktree: URL(fileURLWithPath: item.record.worktreePath))) ?? false
    }

    private func context(_ rec: WorkspaceRecord) -> TemplateContext {
        TemplateContext(
            project: config.project.name, branch: rec.branch,
            port: rec.port, dbName: rec.dbName, worktree: rec.worktreePath)
    }

    private func childEnv(_ rec: WorkspaceRecord) -> [String: String] {
        let url = DatabaseService(shell: shell, renderer: renderer)
            .databaseURL(config.database, ctx: context(rec))
        return ["PORT": String(rec.port), "DATABASE_URL": url]
    }

    // MARK: - Lifecycle actions

    func create(base: String, branch: String) async {
        let log = onLog(branch: branch, process: "create")
        do {
            _ = try await manager.create(
                config: config, repo: rootURL,
                base: base, branch: branch, onLog: log)
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }

    /// Look up a process's command from config; nil if the name is unknown.
    private func command(for name: String) -> String? {
        config.run.processes.first(where: { $0.name == name })?.command
    }

    func startProcess(_ item: WorkspaceItem, name: String) async {
        guard let command = command(for: name) else { return }
        var rec = item.record
        let key = ProcessKey(branch: rec.branch, name: name)
        // terminate any existing pid for this process
        if let existing = rec.processes.first(where: { $0.name == name })?.pid {
            await PosixProcessTerminator().terminate(pid: existing, graceSeconds: 5)
        }
        let sup = ServerSupervisor(shell: shell, renderer: renderer)
        do {
            let pid = try await sup.start(
                command: command, ctx: context(rec),
                cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onLog: onLog(branch: rec.branch, process: name))
            supervisors[key] = sup
            upsertProcess(&rec, ProcessState(name: name, pid: pid, status: .running))
            try store.upsert(rec)
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }

    func stopProcess(_ item: WorkspaceItem, name: String) async {
        var rec = item.record
        let key = ProcessKey(branch: rec.branch, name: name)
        if let sup = supervisors[key] {
            await sup.stop(graceSeconds: 5)
        } else if let pid = rec.processes.first(where: { $0.name == name })?.pid {
            await PosixProcessTerminator().terminate(pid: pid, graceSeconds: 5)
        }
        supervisors[key] = nil
        upsertProcess(&rec, ProcessState(name: name, pid: nil, status: .stopped))
        try? store.upsert(rec)
        refresh()
    }

    func restartProcess(_ item: WorkspaceItem, name: String) async {
        await stopProcess(item, name: name)
        if let fresh = workspaces.first(where: { $0.id == item.id }) {
            await startProcess(fresh, name: name)
        }
    }

    func startAll(_ item: WorkspaceItem) async {
        for proc in config.run.processes {
            let current = workspaces.first(where: { $0.id == item.id }) ?? item
            await startProcess(current, name: proc.name)
        }
    }

    func stopAll(_ item: WorkspaceItem) async {
        for proc in config.run.processes {
            let current = workspaces.first(where: { $0.id == item.id }) ?? item
            await stopProcess(current, name: proc.name)
        }
    }

    /// Replace (or insert) a process state by name and recompute the record's status.
    private func upsertProcess(_ rec: inout WorkspaceRecord, _ state: ProcessState) {
        if let i = rec.processes.firstIndex(where: { $0.name == state.name }) {
            rec.processes[i] = state
        } else {
            rec.processes.append(state)
        }
        rec.status = aggregateStatus(rec.processes)
    }

    func push(_ item: WorkspaceItem) async {
        do {
            try await GitService(shell: shell)
                .push(
                    worktree: URL(fileURLWithPath: item.record.worktreePath),
                    branch: item.record.branch)
        } catch {
            lastError = AppError(error)
        }
    }

    func teardown(_ item: WorkspaceItem, push: Bool, force: Bool) async {
        do {
            try await manager.teardown(
                id: item.record.id, config: config,
                repo: rootURL, push: push, force: force)
            supervisors = supervisors.filter { $0.key.branch != item.record.branch }
            buffers = buffers.filter { $0.key.branch != item.record.branch }
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }
}
