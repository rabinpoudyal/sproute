import Foundation
import SproutEngine

/// A workspace record paired with reconcile-derived liveness info, for display.
struct WorkspaceItem: Identifiable, Equatable {
    var record: WorkspaceRecord
    var orphaned: Bool  // worktree directory missing on disk
    var id: UUID { record.id }
}

/// One running interactive console, for display in the detail view and process list.
struct ConsoleSessionItem: Identifiable, Equatable {
    let id: UUID
    let branch: String
    let name: String
    var status: ConsoleStatus
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
    @Published private(set) var consoleSessions: [ConsoleSessionItem] = []

    private let shell = LoginShellRunner()
    private let renderer = TemplateRenderer()
    private let store: StateStore
    private let manager: WorkspaceManager
    private let loopbackEnabled: Bool
    private let allocator: IPAllocator
    private let loopback: LoopbackCoordinator

    private var buffers: [ProcessKey: LogBuffer] = [:]
    private var supervisors: [ProcessKey: ServerSupervisor] = [:]
    private lazy var consoleSupervisor = ConsoleSupervisor(
        spawner: ForkPTYSpawner(), renderer: renderer)
    private var consoleControllers: [UUID: ConsoleSessionController] = [:]
    private var shellControllers: [String: ConsoleSessionController] = [:]

    var name: String { config.project.name }

    init(
        rootURL: URL, config: Config,
        loopbackEnabled: Bool = false,
        allocator: IPAllocator? = nil,
        loopback: LoopbackCoordinator? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.id = self.rootURL.path
        self.config = config
        let store = JSONStateStore(fileURL: SproutPaths.stateFile(projectName: config.project.name))
        self.store = store
        self.manager = ProjectStore.makeManager(
            config: config, store: store,
            shell: shell, renderer: renderer)
        self.loopbackEnabled = loopbackEnabled
        self.allocator = allocator ?? IPAllocator(fileURL: SproutPaths.loopbackFile)
        self.loopback = loopback ?? LoopbackCoordinator(provisioner: NoopLoopbackProvisioner())
    }

    private static func makeManager(
        config: Config, store: StateStore,
        shell: ShellRunner, renderer: TemplateRenderer
    ) -> WorkspaceManager {
        WorkspaceManager(
            git: GitService(shell: shell),
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

    private func context(_ rec: WorkspaceRecord, process name: String? = nil) -> TemplateContext {
        let plan = portPlan(config.run.processes)
        let own = name.flatMap { plan[$0] } ?? rec.port
        return TemplateContext(
            project: config.project.name, branch: rec.branch,
            port: own, dbName: rec.dbName, worktree: rec.worktreePath, ports: plan,
            host: rec.bindIP)
    }

    private func childEnv(_ rec: WorkspaceRecord, process name: String? = nil) -> [String: String] {
        let ctx = context(rec, process: name)
        let url = DatabaseService(shell: shell, renderer: renderer)
            .databaseURL(config.database, ctx: ctx)
        return [
            "PORT": String(ctx.port), "DATABASE_URL": url,
            "HOST": rec.bindIP, "BIND_IP": rec.bindIP,
        ]
    }

    // MARK: - Lifecycle actions

    /// Hostnames provisioned for this project's port-binding processes.
    private func loopbackHosts() -> [String] {
        loopbackHostnames(project: config.project.name, processes: config.run.processes)
    }

    /// Refcounted provision of the branch's loopback alias + hosts (no-op when the
    /// feature is disabled). Throws if provisioning fails so the caller can abort the
    /// start before spawning a process that would bind an unconfigured IP.
    func activateLoopback(_ rec: WorkspaceRecord) async throws {
        guard loopbackEnabled else { return }
        try await loopback.activate(branch: rec.branch, ip: rec.bindIP, hosts: loopbackHosts())
    }

    /// Refcounted release of the branch's loopback alias + hosts (no-op when the
    /// feature is disabled). Never throws — stale state is reaped by the launch sweep.
    func deactivateLoopback(_ rec: WorkspaceRecord) async {
        guard loopbackEnabled else { return }
        await loopback.deactivate(branch: rec.branch, ip: rec.bindIP, hosts: loopbackHosts())
    }

    /// The bind IP for a new workspace: an allocated 127.0.10.N when the loopback
    /// feature is on, otherwise 127.0.0.1 (so disabled mode keeps today's behavior).
    func allocateBindIP(branch: String) async throws -> String {
        guard loopbackEnabled else { return "127.0.0.1" }
        return try await allocator.allocate(project: config.project.name, branch: branch)
    }

    func create(base: String, branch: String) async {
        // Route each stream ("setup" + per-process) to its own buffer so the detail
        // view's per-process consoles show create-time output, not just an unseen
        // "create" buffer.
        let route: @Sendable (String, LogLine) -> Void = { [weak self] stream, line in
            Task { @MainActor in self?.logBuffer(branch: branch, process: stream).append(line) }
        }
        let onExit: @Sendable (String, Int32, Int32) -> Void = { [weak self] name, pid, code in
            Task { @MainActor in
                self?.handleProcessExit(branch: branch, name: name, pid: pid, code: code)
            }
        }
        do {
            let bindIP = try await allocateBindIP(branch: branch)
            _ = try await manager.create(
                config: config, repo: rootURL,
                base: base, branch: branch, bindIP: bindIP, log: route, onProcessExit: onExit)
            refresh()
        } catch {
            lastError = AppError(error)
        }
    }

    /// A started process exited. Flip its persisted state to `.crashed` (nonzero) or
    /// `.stopped` (clean) so the UI stops showing a dead process as running. Guarded by a
    /// pid match so a late exit from a process we already stopped or restarted is ignored.
    private func handleProcessExit(branch: String, name: String, pid: Int32, code: Int32) {
        guard var rec = try? store.load().first(where: { $0.branch == branch }),
            let i = rec.processes.firstIndex(where: { $0.name == name }),
            rec.processes[i].pid == pid
        else { return }
        rec.processes[i].status = (code == 0) ? .stopped : .crashed
        rec.processes[i].pid = nil
        rec.status = aggregateStatus(rec.processes)
        try? store.upsert(rec)
        refresh()
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
        let branch = rec.branch
        let onExit: @Sendable (Int32, Int32) -> Void = { [weak self] pid, code in
            Task { @MainActor in
                self?.handleProcessExit(branch: branch, name: name, pid: pid, code: code)
            }
        }
        do {
            let pid = try await sup.start(
                command: command, ctx: context(rec, process: name),
                cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec, process: name), onLog: onLog(branch: rec.branch, process: name),
                onExit: onExit)
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

    // MARK: - Consoles

    /// The configured console command for a name, or nil if unknown.
    private func consoleCommand(for name: String) -> String? {
        config.run.consoles.first(where: { $0.name == name })?.command
    }

    /// The SwiftTerm-backed view controller for a running console, if any.
    func consoleController(id: UUID) -> ConsoleSessionController? {
        consoleControllers[id]
    }

    /// Start a new console session for `name` on the workspace's branch.
    func startConsole(_ item: WorkspaceItem, name: String) async {
        guard let command = consoleCommand(for: name) else { return }
        let rec = item.record
        let branch = rec.branch
        let onExit: @Sendable (UUID, Int32) -> Void = { [weak self] id, _ in
            Task { @MainActor in self?.handleConsoleExit(id: id) }
        }
        do {
            let session = try await consoleSupervisor.start(
                branch: branch, name: name, command: command,
                ctx: context(rec), cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onExit: onExit)
            consoleControllers[session.id] = ConsoleSessionController(
                id: session.id, handle: session.handle)
            await refreshConsoles(branch: branch)
        } catch {
            lastError = AppError(error)
        }
    }

    /// The SwiftTerm controller for a branch's drawer shell, if a session is running.
    func shellController(branch: String) -> ConsoleSessionController? {
        shellControllers[branch]
    }

    /// Lazily start the branch's interactive drawer shell. No-op if one already runs.
    /// Runs in the worktree with the workspace's child env (PORT, DATABASE_URL).
    func openShell(_ item: WorkspaceItem) async {
        let rec = item.record
        let branch = rec.branch
        if shellControllers[branch] != nil { return }
        let onExit: @Sendable (UUID, Int32) -> Void = { [weak self] _, _ in
            Task { @MainActor in self?.handleShellExit(branch: branch) }
        }
        do {
            let session = try await consoleSupervisor.startShell(
                branch: branch, cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec), onExit: onExit)
            shellControllers[branch] = ConsoleSessionController(
                id: session.id, handle: session.handle)
            objectWillChange.send()
        } catch {
            lastError = AppError(error)
        }
    }

    /// The shell exited (user typed `exit`/Ctrl-D, or it crashed). Drop the controller so
    /// the drawer shows its placeholder; the next `openShell` starts a fresh session.
    private func handleShellExit(branch: String) {
        shellControllers[branch]?.stop()
        shellControllers[branch] = nil
        objectWillChange.send()
    }

    func stopConsole(id: UUID) async {
        let branch = consoleSessions.first(where: { $0.id == id })?.branch
        consoleControllers[id]?.stop()
        consoleControllers[id] = nil
        await consoleSupervisor.stop(id: id)
        if let branch { await refreshConsoles(branch: branch) }
    }

    /// A console exited on its own (user typed `exit`, or it crashed). Drop its controller
    /// and refresh the list so the UI removes it.
    private func handleConsoleExit(id: UUID) {
        let branch = consoleSessions.first(where: { $0.id == id })?.branch
        consoleControllers[id]?.stop()
        consoleControllers[id] = nil
        Task { if let branch { await refreshConsoles(branch: branch) } }
    }

    /// Rebuild `consoleSessions` for one branch from the supervisor's truth, preserving
    /// sessions on other branches.
    private func refreshConsoles(branch: String) async {
        let infos = await consoleSupervisor.list(branch: branch)
        var others = consoleSessions.filter { $0.branch != branch }
        others.append(
            contentsOf: infos.map {
                ConsoleSessionItem(id: $0.id, branch: $0.branch, name: $0.name, status: $0.status)
            })
        consoleSessions = others
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
            await consoleSupervisor.killAll(branch: item.record.branch)
            for (id, c) in consoleControllers
            where consoleSessions.contains(where: {
                $0.id == id && $0.branch == item.record.branch
            }) {
                c.stop()
                consoleControllers[id] = nil
            }
            consoleSessions = consoleSessions.filter { $0.branch != item.record.branch }
            shellControllers[item.record.branch]?.stop()
            shellControllers[item.record.branch] = nil
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
