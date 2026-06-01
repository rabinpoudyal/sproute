import Foundation
import SproutEngine

/// A workspace record paired with reconcile-derived liveness info, for display.
struct WorkspaceItem: Identifiable, Equatable {
    var record: WorkspaceRecord
    var orphaned: Bool           // worktree directory missing on disk
    var id: UUID { record.id }
}

/// View-model for a single registered project. Wraps the headless engine
/// (`WorkspaceManager` + friends) and exposes UI-friendly state and actions.
@MainActor
final class ProjectStore: ObservableObject, Identifiable {
    nonisolated let id: String          // normalized root path
    let rootURL: URL
    let config: Config

    @Published private(set) var workspaces: [WorkspaceItem] = []
    @Published private(set) var doctor: [ToolCheck] = []
    @Published var lastError: AppError?

    private let shell = LoginShellRunner()
    private let renderer = TemplateRenderer()
    private let store: StateStore
    private let manager: WorkspaceManager

    private var buffers: [String: LogBuffer] = [:]
    private var supervisors: [String: ServerSupervisor] = [:]

    var name: String { config.project.name }

    init(rootURL: URL, config: Config) {
        self.rootURL = rootURL.standardizedFileURL
        self.id = self.rootURL.path
        self.config = config
        let store = JSONStateStore(fileURL: SproutPaths.stateFile(projectName: config.project.name))
        self.store = store
        self.manager = ProjectStore.makeManager(config: config, store: store,
                                                 shell: shell, renderer: renderer)
    }

    private static func makeManager(config: Config, store: StateStore,
                                    shell: ShellRunner, renderer: TemplateRenderer) -> WorkspaceManager {
        WorkspaceManager(
            git: GitService(shell: shell),
            portAllocator: PortAllocator(config: config.port, store: store, prober: BindPortProber()),
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

    func logBuffer(for branch: String) -> LogBuffer {
        if let b = buffers[branch] { return b }
        let b = LogBuffer(id: branch)
        buffers[branch] = b
        return b
    }

    private func onLog(for branch: String) -> @Sendable (LogLine) -> Void {
        let buffer = logBuffer(for: branch)
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
        TemplateContext(project: config.project.name, branch: rec.branch,
                        port: rec.port, dbName: rec.dbName, worktree: rec.worktreePath)
    }

    private func childEnv(_ rec: WorkspaceRecord) -> [String: String] {
        let url = DatabaseService(shell: shell, renderer: renderer)
            .databaseURL(config.database, ctx: context(rec))
        return ["PORT": String(rec.port), "DATABASE_URL": url]
    }

    // MARK: - Lifecycle actions

    func create(base: String, branch: String) async {
        let log = onLog(for: branch)
        do {
            _ = try await manager.create(config: config, repo: rootURL,
                                         base: base, branch: branch, onLog: log)
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }

    func startOrRestartServer(_ item: WorkspaceItem) async {
        var rec = item.record
        let log = onLog(for: rec.branch)
        if let pid = rec.serverPID {
            await PosixProcessTerminator().terminate(pid: pid, graceSeconds: 5)
        }
        let sup = ServerSupervisor(shell: shell, renderer: renderer)
        do {
            let pid = try await sup.start(command: config.run.serverCommand,
                                          ctx: context(rec),
                                          cwd: URL(fileURLWithPath: rec.worktreePath),
                                          env: childEnv(rec), onLog: log)
            supervisors[rec.branch] = sup
            rec.serverPID = pid
            rec.status = .running
            try store.upsert(rec)
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }

    func stopServer(_ item: WorkspaceItem) async {
        var rec = item.record
        if let sup = supervisors[rec.branch] {
            await sup.stop(graceSeconds: 5)
        } else if let pid = rec.serverPID {
            await PosixProcessTerminator().terminate(pid: pid, graceSeconds: 5)
        }
        supervisors[rec.branch] = nil
        rec.serverPID = nil
        rec.status = .stopped
        try? store.upsert(rec)
        refresh()
    }

    func push(_ item: WorkspaceItem) async {
        do {
            try await GitService(shell: shell)
                .push(worktree: URL(fileURLWithPath: item.record.worktreePath),
                      branch: item.record.branch)
        } catch {
            lastError = AppError(error)
        }
    }

    func teardown(_ item: WorkspaceItem, push: Bool, force: Bool) async {
        do {
            try await manager.teardown(id: item.record.id, config: config,
                                       repo: rootURL, push: push, force: force)
            supervisors[item.record.branch] = nil
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }
}
